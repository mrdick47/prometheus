import hashlib
import json
import os
import threading
import time

import numpy as np
import pytest
from conftest import make_zim, page_html

from prometheus_index import engine, ops
from prometheus_index.config import is_verified, source_id
from prometheus_index.engine import (Cancelled, Interrupted, Log, Run, SimulatedCrash, Stopper,
                                     config_signature, control_path, write_control)
from prometheus_index.extract import chunk_offsets, html_to_text
from prometheus_index.fsutil import atomic_write_bytes
from prometheus_index.lockfile import LockBusy, SourceLock
from prometheus_index.store import IndexStore

LOG = Log(None, echo=False)


def run(env, src, mode="build", **kw):
    return Run(src, mode, env.emb, env.settings, LOG, **kw).execute()


def sig(env):
    return config_signature(env.emb)


def state(env, src):
    return ops.classify(src, sig(env))[0]


def articles(src):
    st = IndexStore(src.index_dir, readonly=True)
    try:
        return dict((p, h) for p, h in st.db.execute("SELECT path,hash FROM articles"))
    finally:
        st.close()


# ---- extraction --------------------------------------------------------------
def test_html_text_skips_script_and_chunks_are_offsets():
    t = html_to_text(page_html("alpha").encode())
    assert "var x=1" not in t and "alpha paragraph 0" in t
    tb = t.encode()
    offs = chunk_offsets(tb)
    assert offs and all(0 <= s < e <= len(tb) for s, e in offs)
    assert all(e - s <= 1200 for s, e in offs)
    for s, e in offs:
        tb[s:e].decode("utf-8")  # always valid utf-8


def test_chunk_offsets_utf8_boundaries():
    tb = ("é" * 3000).encode()
    for s, e in chunk_offsets(tb):
        tb[s:e].decode("utf-8")


# ---- atomic write / lock -----------------------------------------------------
def test_atomic_write_leaves_no_temp(tmp_path):
    p = tmp_path / "x.json"
    atomic_write_bytes(p, b"1")
    atomic_write_bytes(p, b"22")
    assert p.read_bytes() == b"22" and [f.name for f in tmp_path.iterdir()] == ["x.json"]


def test_lock_busy_and_stale_takeover(tmp_path):
    lp = tmp_path / "s.lock"
    a = SourceLock(lp)
    a.acquire()
    with pytest.raises(LockBusy):
        SourceLock(lp).acquire()
    a.release()
    # stale: same host, dead pid
    lp.write_text(json.dumps({"host": engine.hostname(), "pid": 2 ** 22 + 12345, "heartbeat": time.time()}))
    b = SourceLock(lp)
    b.acquire()
    b.release()
    # stale: old heartbeat from another host
    lp.write_text(json.dumps({"host": "OTHERHOST", "pid": 1, "heartbeat": time.time() - 99999}))
    c = SourceLock(lp, stale_after=60)
    c.acquire()
    c.release()
    # live lock from another host is respected
    lp.write_text(json.dumps({"host": "OTHERHOST", "pid": 1, "heartbeat": time.time()}))
    with pytest.raises(LockBusy):
        SourceLock(lp, stale_after=60).acquire()
    # torn lock file is treated as stale
    lp.write_text("{")
    SourceLock(lp).acquire()


def test_verified_marker_required(env):
    s = env.zim()
    assert is_verified(env.root, s.zim)
    (env.root / "run" / "verified" / (s.zim.name + ".verified.json")).write_text(
        json.dumps({"filename": s.zim.name, "size": 1}))
    assert not is_verified(env.root, s.zim)  # size mismatch
    assert source_id("wikipedia_en_all_maxi_2026-08.zim") == "wikipedia_en_all_maxi"


# ---- build, update, no-text-stored ------------------------------------------
def test_build_and_update_unchanged_is_fast(env):
    s = env.zim()
    r = run(env, s)
    assert r["status"] == "ok" and r["articles"] >= 5 and r["chunks"] > 5
    assert r["skipped_nontext"] >= 1   # the png
    assert state(env, s) == "up to date"
    r2 = run(env, s, "update")
    assert r2["status"] == "up-to-date"
    # build again on a finished index is a no-op
    assert run(env, s, "build")["status"] == "exists"
    # no chunk text on disk
    blob = b"".join(p.read_bytes() for p in s.index_dir.iterdir() if p.is_file())
    assert b"fact number" not in blob


def test_update_embeds_only_changed_and_drops_deleted(env):
    pages = {f"A/{t}": page_html(t) for t in ["alpha", "beta", "gamma", "delta"]}
    s = env.zim(pages=pages)
    run(env, s)
    before = articles(s)
    pages2 = dict(pages)
    pages2["A/beta"] = page_html("beta changed", 3)   # changed
    del pages2["A/delta"]                              # deleted
    pages2["A/zeta"] = page_html("zeta")               # new
    s = env.zim(pages=pages2)
    r = run(env, s, "update")
    assert r["status"] == "ok"
    assert r["embedded_articles"] == 2 and r["unchanged"] >= 2 and r["removed"] == 1
    after = articles(s)
    assert {"A/alpha", "A/beta", "A/gamma", "A/zeta"} <= set(after) and "A/delta" not in after
    assert after["A/alpha"] == before["A/alpha"] and after["A/beta"] != before["A/beta"]
    st = IndexStore(s.index_dir, readonly=True)
    assert st.stats()["dead_rows"] > 0        # old rows kept until rebuild, but never returned
    for h in st.search(env.emb.embed(["beta changed"], True)[0], k=20):
        assert h["path"] != "A/delta"
    st.close()
    assert ops.verify_source(s, sig(env), deep=True)["state"] == "up to date"


# ---- checkpoint / resume -----------------------------------------------------
def test_crash_then_resume_matches_clean_build(env, tmp_path):
    pages = {f"A/t{i}": page_html(f"topic{i}") for i in range(12)}
    s = env.zim(pages=pages)
    with pytest.raises(SimulatedCrash):
        run(env, s, crash_after=2)
    st = IndexStore(s.index_dir, readonly=True)
    assert st.get("run_state") == "running" and int(st.get("cursor")) >= 0
    n_ck = int(st.get("cursor"))
    st.close()
    assert state(env, s) == "building"
    r = run(env, s)   # resumes, does not restart
    assert r["status"] == "ok"
    resumed = articles(s)
    # clean reference build on a second drive
    from conftest import Env
    ref_env = Env(tmp_path / "ref")
    s2 = ref_env.zim(pages=pages)
    Run(s2, "build", ref_env.emb, ref_env.settings, LOG).execute()
    assert resumed == articles(s2)
    a, b = IndexStore(s.index_dir, readonly=True), IndexStore(s2.index_dir, readonly=True)
    assert a.stats()["chunks"] == b.stats()["chunks"]
    q = env.emb.embed(["topic7 paragraph 3"], True)[0]
    assert [(h["path"], h["start"]) for h in a.search(q, 5)] == [(h["path"], h["start"]) for h in b.search(q, 5)]
    a.close(); b.close()


def test_resume_does_not_reembed_committed_articles(env):
    pages = {f"A/t{i}": page_html(f"topic{i}") for i in range(12)}
    s = env.zim(pages=pages)
    with pytest.raises(SimulatedCrash):
        run(env, s, crash_after=1)
    st = IndexStore(s.index_dir, readonly=True)
    done = st.stats()["articles"]
    st.close()
    r = run(env, s)
    assert done > 0 and r["embedded_articles"] + done == r["articles"]


def test_orphan_segment_from_uncommitted_checkpoint_is_removed(env):
    s = env.zim()
    run(env, s)
    (s.index_dir / "seg-000099.vec").write_bytes(b"x" * 10)
    (s.index_dir / "junk.tmp").write_bytes(b"x")
    assert any("orphan" in p for p in IndexStore(s.index_dir, readonly=True).verify_files())
    IndexStore(s.index_dir).close()          # writer open cleans up
    assert not (s.index_dir / "seg-000099.vec").exists() and not (s.index_dir / "junk.tmp").exists()


def test_checkpoint_rollback_on_failure_keeps_previous_state(env, monkeypatch):
    s = env.zim()
    st = IndexStore(s.index_dir, dim=32)
    st.begin_run()
    v = np.zeros((1, 32), np.int8)
    recs = np.zeros(1, dtype=__import__("prometheus_index.store", fromlist=["REC_DTYPE"]).REC_DTYPE)
    st.checkpoint(v, recs, [("p", "h", 0, 1)], [], 3)
    monkeypatch.setattr("prometheus_index.store._write_seg", lambda *a: (_ for _ in ()).throw(OSError("disk full")))
    with pytest.raises(OSError):
        st.checkpoint(v, recs, [("q", "h", 0, 1)], [], 9)
    assert st.get("cursor") == "3" and st.article_by_path("q") is None
    st.close()


# ---- interrupt / pause / cancel ---------------------------------------------
def test_interrupt_flag_checkpoints_and_resumes(env):
    pages = {f"A/t{i}": page_html(f"topic{i}") for i in range(10)}
    s = env.zim(pages=pages)
    stopper = Stopper()
    stopper.flag = True       # as if Ctrl-C arrived immediately
    assert run(env, s, stopper=stopper)["status"] == "interrupted"
    assert not s.lock_path.exists()   # lock released
    assert run(env, s)["status"] == "ok"
    assert state(env, s) == "up to date"


def test_pause_resume_and_cancel_keep_progress(env):
    pages = {f"A/t{i}": page_html(f"topic{i}") for i in range(10)}
    s = env.zim(pages=pages)
    write_control(s.drive, s.id, "pause")
    out = {}
    t = threading.Thread(target=lambda: out.update(run(env, s)))
    t.start()
    for _ in range(100):
        j = json.loads(open(engine.job_path(s.drive, s.id)).read()) if engine.job_path(s.drive, s.id).exists() else {}
        if j.get("state") == "paused":
            break
        time.sleep(0.1)
    assert j.get("state") == "paused"
    write_control(s.drive, s.id, "resume")
    t.join(timeout=30)
    assert out.get("status") == "ok"
    # cancel keeps progress
    pages2 = {f"B/t{i}": page_html(f"other{i}") for i in range(10)}
    s2 = env.zim(name="other_en_2026-01.zim", pages=pages2)
    write_control(s2.drive, s2.id, "cancel")
    assert run(env, s2)["status"] == "cancelled"
    assert (s2.index_dir / "state.db").exists()
    assert not control_path(s2.drive, s2.id).exists()
    assert run(env, s2)["status"] == "ok"
    # cancel --discard wipes a never-finished build
    s3 = env.zim(name="third_en_2026-01.zim", pages=pages2)
    write_control(s3.drive, s3.id, "cancel-discard")
    r = run(env, s3)
    assert r["status"] == "cancelled" and r["discarded"] and not s3.index_dir.exists()


# ---- rebuild -----------------------------------------------------------------
def test_rebuild_swaps_and_failed_rebuild_keeps_old(env, monkeypatch):
    s = env.zim()
    run(env, s)
    old_created = IndexStore(s.index_dir, readonly=True).get("created")
    # failed rebuild: crash mid-way; old index keeps working
    with pytest.raises(SimulatedCrash):
        run(env, s, "rebuild", crash_after=1)
    assert s.rebuild_dir.exists()
    st = IndexStore(s.index_dir, readonly=True)
    assert st.get("created") == old_created and st.search(env.emb.embed(["alpha"], True)[0], 3)
    st.close()
    assert state(env, s) == "building"           # status shows the pending rebuild
    r = run(env, s, "rebuild")                   # resumes the partial rebuild, then swaps
    assert r["status"] == "ok" and not s.rebuild_dir.exists() and not s.old_dir.exists()
    assert IndexStore(s.index_dir, readonly=True).get("created") != old_created
    assert state(env, s) == "up to date"


def test_interrupted_swap_recovery(env):
    s = env.zim()
    run(env, s)
    run(env, s, "rebuild")  # complete rebuild, swapped
    # Simulate crash between the two renames: live gone, new complete, old present
    import shutil
    shutil.copytree(s.index_dir, s.rebuild_dir)
    os.replace(s.index_dir, s.old_dir)
    engine.recover_swap(s, LOG)
    assert (s.index_dir / "state.db").exists() and not s.old_dir.exists()
    # crash after first rename with incomplete new: previous index restored
    shutil.rmtree(s.rebuild_dir, ignore_errors=True)
    os.replace(s.index_dir, s.old_dir)
    s.rebuild_dir.mkdir()
    (s.rebuild_dir / "state.db").write_bytes(b"not a db")
    engine.recover_swap(s, LOG)
    assert (s.index_dir / "state.db").exists()


def test_model_mismatch_flagged_and_rebuild_fixes(env):
    s = env.zim()
    run(env, s)
    from prometheus_index.embed import HashEmbedder
    other = HashEmbedder({"dim": 48, "name": "hash-test"})
    assert ops.classify(s, config_signature(other))[0] == "model-mismatch"
    r = Run(s, "update", other, env.settings, LOG).execute()
    assert r["status"] == "model-mismatch"
    r = Run(s, "rebuild", other, env.settings, LOG).execute()
    assert r["status"] == "ok"
    assert ops.classify(s, config_signature(other))[0] == "up to date"


# ---- verify / status ---------------------------------------------------------
def test_verify_detects_corrupt_missing_stale_and_orphan(env):
    s = env.zim()
    run(env, s)
    assert ops.verify_source(s, sig(env), deep=True, emb=env.emb)["self_retrieval"].split("/")[0] != "0"
    vec = s.index_dir / "seg-000001.vec"
    raw = bytearray(vec.read_bytes())
    raw[0] ^= 0x7F
    vec.write_bytes(bytes(raw))
    assert ops.verify_source(s, sig(env))["state"] == "up to date"           # shallow: size ok
    r = ops.verify_source(s, sig(env), deep=True)
    assert r["state"] == "corrupt" and any("checksum" in p for p in r["problems"])
    vec.write_bytes(b"short")
    r = ops.verify_source(s, sig(env))
    assert r["state"] == "corrupt" and any("size" in p for p in r["problems"])
    vec.unlink()
    assert any("missing" in p for p in ops.verify_source(s, sig(env))["problems"])
    # stale: new ZIM content
    env2 = env
    s2 = env2.zim(name="b_en_2026-01.zim")
    run(env, s2)
    s2 = env2.zim(name="b_en_2026-01.zim", pages={"A/new": page_html("new")})
    assert ops.verify_source(s2, sig(env))["state"] == "stale"
    # missing index
    s3 = env.zim(name="c_en_2026-01.zim")
    assert ops.classify(s3, sig(env))[0] == "none"
    # orphan: index dir without ZIM
    s2.zim.unlink()
    out = ops.status([env.root], env.settings, sig(env))
    assert "orphaned" in out and "none" in out or "orphaned" in out


def test_verify_detects_corrupt_database(env):
    s = env.zim()
    run(env, s)
    (s.index_dir / "state.db").write_bytes(b"garbage" * 100)
    r = ops.verify_source(s, sig(env))
    assert r["state"] in ("failed", "corrupt") and r["problems"]


def test_query_reads_text_back_from_zim_via_offsets(env):
    s = env.zim()
    run(env, s)
    hits = ops.query([s], env.emb, "gamma paragraph 2 fact number 2", k=3)
    assert hits and hits[0]["path"] == "A/gamma"
    assert "gamma" in hits[0]["snippet"] and not hits[0]["stale"]
    assert hits[0]["snippet"] == hits[0]["snippet"].strip()


def test_remove_deletes_only_that_source(env):
    s = env.zim()
    s2 = env.zim(name="other_en_2026-01.zim")
    run(env, s); run(env, s2)
    ops.remove_index(s)
    assert not s.index_dir.exists() and s2.index_dir.exists() and not s.lock_path.exists()


def test_systematic_entry_errors_fail_the_run_instead_of_completing(env, monkeypatch):
    s = env.zim(pages={f"A/t{i}": page_html(f"topic{i}") for i in range(80)})
    monkeypatch.setattr("prometheus_index.engine.entry_getter",
                        lambda arc: (_ for _ in ()).throw(AttributeError("api")) if False else
                        (lambda i: (_ for _ in ()).throw(AttributeError("api"))))
    with pytest.raises(engine.TooManyErrors):
        run(env, s)
    assert state(env, s) == "building"        # not marked complete
    monkeypatch.undo()
    assert run(env, s)["status"] == "ok"      # recovers on the next run


def test_update_after_errors_retries_instead_of_fast_path(env):
    s = env.zim()
    run(env, s)
    st = IndexStore(s.index_dir)
    st.set_many({"errors": 3})
    st.close()
    r = run(env, s, "update")
    assert r["status"] == "ok" and r["errors"] == 0


def test_query_skips_index_built_with_other_extractor(env, monkeypatch):
    s = env.zim()
    run(env, s)
    assert ops.query([s], env.emb, "alpha", k=2)
    monkeypatch.setattr("prometheus_index.extract.EXTRACTOR_VERSION", "other")
    assert ops.query([s], env.emb, "alpha", k=2) == []
