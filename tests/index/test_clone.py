"""`index clone`: drive-to-drive index copy (standalone mirror and shared BAC-187 layouts)."""
import json
import os
import shutil
import threading
import time
from pathlib import Path

import pytest
from conftest import Env, page_html

from prometheus_index import cli, ops
from prometheus_index.clone import (DRIVE_MARKER, Cloner, Options, build_plan, detect_layout,
                                    fit_plan, inspect_index, zim_uuid)
from prometheus_index.engine import Log, Run, SimulatedCrash, config_signature, job_path, write_control
from prometheus_index.fsutil import sha256_file
from prometheus_index.store import IndexStore

GIB = 1 << 30


class MemLog(Log):
    def __init__(self):
        super().__init__(None, echo=False)
        self.lines = []

    def _w(self, level, msg):
        self.lines.append(f"[{level}] {msg}")

    def text(self):
        return "\n".join(self.lines)


def pages(tag, n=8):
    return {f"A/{tag}{i}": page_html(f"{tag}{i}") for i in range(n)}


class Pair:
    """J (source drive, indexes built) and I (target drive)."""

    def __init__(self, tmp_path):
        self.j = Env(tmp_path / "J")
        self.i = Env(tmp_path / "I")
        self.log = MemLog()

    def source(self, name, tag, on_target=True, build=True):
        s = self.j.zim(name=f"{name}_en_2026-01.zim", pages=pages(tag))
        if build:
            assert Run(s, "build", self.j.emb, self.j.settings, Log(None, echo=False)).execute()["status"] == "ok"
        if on_target:
            self.put_on_target(s)
        return s

    def put_on_target(self, s):
        (self.i.root / "library").mkdir(parents=True, exist_ok=True)
        shutil.copy2(s.zim, self.i.root / "library" / s.zim.name)
        marker = f"{s.zim.name}.verified.json"
        shutil.copy2(self.j.root / "run" / "verified" / marker, self.i.root / "run" / "verified" / marker)

    def opts(self, **kw):
        kw.setdefault("headroom_bytes", 0)
        return Options(self.j.root, self.i.root, **kw)

    def plan(self, **kw):
        return build_plan(self.opts(**kw), self.log, self.j.settings)

    def cloner(self, plan, **kw):
        c = Cloner(plan, self.j.settings, self.log, **kw)
        c.ctl_interval = 0.0
        return c

    def clone(self, **kw):
        p = self.plan(**kw)
        c = self.cloner(p)
        return p, c.run(), c

    def target_index(self, sid):
        return self.i.root / "index" / sid


@pytest.fixture
def pair(tmp_path):
    return Pair(tmp_path)


def tree_hash(d: Path):
    return {p.name: sha256_file(p) for p in sorted(Path(d).iterdir()) if p.is_file() and p.name != ".clone.json"}


def by_id(plan, sid):
    return next(i for i in plan.items if i.id == sid)


def idx_bytes(src):
    return inspect_index(src.index_dir)["bytes"]


# ---- match -> copy ------------------------------------------------------------
def test_zim_uuid_reads_header(pair):
    s = pair.source("alpha", "alpha")
    from libzim.reader import Archive
    assert zim_uuid(s.zim) == str(Archive(str(s.zim)).uuid)
    assert zim_uuid(Path(__file__)) is None


def test_matching_zim_copies_index_verified(pair):
    s = pair.source("alpha", "alpha")
    before = tree_hash(s.index_dir)
    plan, code, _c = pair.clone()
    assert code == 0 and by_id(plan, s.id).status == "copied"
    t = pair.target_index(s.id)
    assert tree_hash(t) == before   # byte-identical to source
    st = IndexStore(t, readonly=True)
    assert st.verify_files(deep=True) == []
    st.close()
    assert ops.classify(Source_on(pair.i, s), config_signature(pair.j.emb))[0] == "up to date"
    # nothing left behind, source untouched, target ZIM untouched
    assert sorted(p.name for p in (pair.i.root / "index").iterdir() if p.name.startswith(".")) == []
    assert tree_hash(s.index_dir) == before
    assert not list(t.glob("*.tmp"))
    # second run is a no-op
    plan2, code2, _ = pair.clone()
    assert code2 == 0 and by_id(plan2, s.id).status == "up-to-date"


def Source_on(env, s):
    from prometheus_index.config import Source
    return Source(id=s.id, drive=env.root, zim=env.root / "library" / s.zim.name)


# ---- ZIM mismatch -> not copied, flagged ---------------------------------------
def test_zim_mismatch_is_skipped_and_flagged(pair):
    a = pair.source("alpha", "alpha")
    b = pair.source("bravo", "bravo", on_target=False)
    # target has a different build of bravo (same name, other content)
    other = Env(pair.i.root.parent / "scratch").zim(name=b.zim.name, pages=pages("different")).zim
    (pair.i.root / "library").mkdir(parents=True, exist_ok=True)
    shutil.copy2(other, pair.i.root / "library" / b.zim.name)
    plan, code, _ = pair.clone()
    assert code == 0
    assert by_id(plan, a.id).status == "copied"
    ib = by_id(plan, b.id)
    assert ib.status == "skipped" and ib.reason.startswith("zim-differs")
    assert not pair.target_index(b.id).exists()
    assert "zim-differs" in pair.log.text() or ib.reason


def test_target_zim_with_other_version_name_is_a_mismatch(pair):
    a = pair.source("alpha", "alpha", on_target=False)
    z = Env(pair.i.root.parent / "scratch2").zim(name="alpha_en_2025-06.zim", pages=pages("old")).zim
    (pair.i.root / "library").mkdir(parents=True, exist_ok=True)
    shutil.copy2(z, pair.i.root / "library" / z.name)
    plan = pair.plan()
    assert by_id(plan, a.id).reason.startswith("zim-differs")


# ---- priority preset ------------------------------------------------------------
def test_priority_preset_filters_and_orders(pair):
    pair.source("alpha", "alpha")
    pair.source("bravo", "bravo")
    pair.source("charlie", "charlie")
    (pair.i.root / "config").mkdir()
    (pair.i.root / "config" / "clone.conf").write_text(
        "[clone]\nsources=bravo_en, alpha_en\n")
    plan = pair.plan()
    assert [i.id for i in plan.items] == ["bravo_en", "alpha_en"]       # priority order, charlie dropped
    assert "charlie_en: not in the target's priority preset" in pair.log.text()
    _p, code, _ = pair.clone()
    assert code == 0
    assert pair.target_index("bravo_en").exists() and pair.target_index("alpha_en").exists()
    assert not pair.target_index("charlie_en").exists()


def test_preset_glob_and_positional_filter(pair):
    pair.source("alpha", "alpha")
    pair.source("alphabet", "abc")
    pair.source("bravo", "bravo")
    (pair.i.root / "config").mkdir()
    (pair.i.root / "config" / "clone.conf").write_text("[clone]\nsources=alpha*\n")
    assert sorted(i.id for i in pair.plan().items) == ["alpha_en", "alphabet_en"]
    assert [i.id for i in pair.plan(only=["alpha_en"]).items] == ["alpha_en"]


def test_unverified_and_deferred_sources_never_cloned(pair):
    pair.source("alpha", "alpha")
    pair.j.settings["defer_ocr"] = "alpha_en"
    assert pair.plan().items == []


# ---- standalone vs shared ---------------------------------------------------------
def test_standalone_skips_source_without_local_content_shared_copies_it(pair):
    s = pair.source("alpha", "alpha", on_target=False)
    sp = pair.plan(layout="standalone")
    it = by_id(sp, s.id)
    assert it.action == "skip" and it.reason.startswith("no-local-content")
    _p, code, _ = pair.clone(layout="standalone")
    assert code == 0 and not pair.target_index(s.id).exists()
    # shared: index copied, ZIM stays on the other drive
    plan, code, _ = pair.clone(layout="shared")
    assert code == 0 and by_id(plan, s.id).status == "copied"
    assert pair.target_index(s.id).exists()
    assert not (pair.i.root / "library" / s.zim.name).exists()
    assert IndexStore(pair.target_index(s.id), readonly=True).verify_files(deep=True) == []


def test_layout_detection_from_drive_markers_and_safe_default(pair, tmp_path):
    log = MemLog()
    assert detect_layout(pair.j.root, pair.i.root, "auto", "auto", log) == "standalone"
    (pair.j.root / DRIVE_MARKER).write_text(json.dumps({"set_id": "S1", "drive_id": "j"}))
    assert detect_layout(pair.j.root, pair.i.root, "auto", "auto", log) == "standalone"   # one marker only
    (pair.i.root / DRIVE_MARKER).write_text(json.dumps({"set_id": "OTHER", "drive_id": "i"}))
    assert detect_layout(pair.j.root, pair.i.root, "auto", "auto", log) == "standalone"
    (pair.i.root / DRIVE_MARKER).write_text(json.dumps({"set_id": "S1", "drive_id": "i"}))
    assert detect_layout(pair.j.root, pair.i.root, "auto", "auto", log) == "shared"
    assert detect_layout(pair.j.root, pair.i.root, "standalone", "auto", log) == "standalone"  # flag wins
    assert detect_layout(pair.j.root, pair.i.root, "auto", "standalone", log) == "standalone"  # preset wins markers


def test_shared_layout_via_markers_copies_index_without_content(pair):
    s = pair.source("alpha", "alpha", on_target=False)
    for env, d in ((pair.j, "j"), (pair.i, "i")):
        (env.root / DRIVE_MARKER).write_text(json.dumps({"set_id": "S1", "drive_id": d}))
    plan, code, _ = pair.clone()           # layout auto
    assert plan.layout == "shared" and code == 0 and pair.target_index(s.id).exists()


def test_with_content_copies_zim_marker_and_index(pair):
    s = pair.source("alpha", "alpha", on_target=False)
    plan, code, _ = pair.clone(layout="standalone", with_content=True)
    assert code == 0 and by_id(plan, s.id).copy_zim
    z = pair.i.root / "library" / s.zim.name
    assert sha256_file(z) == sha256_file(s.zim)
    assert (pair.i.root / "run" / "verified" / (s.zim.name + ".verified.json")).is_file()
    assert not list((pair.i.root / "library").glob("*.tmp"))
    assert pair.target_index(s.id).exists()


# ---- fit budget: content + index together --------------------------------------
def test_budget_counts_index_bytes_with_content(pair):
    s = pair.source("alpha", "alpha", on_target=False)
    z, ix = s.zim.stat().st_size, idx_bytes(s)
    assert ix > 0
    # fits without its index but not with it -> excluded
    plan = pair.plan(layout="standalone", with_content=True, budget_bytes=z + ix - 1)
    it = by_id(plan, s.id)
    assert it.action == "excluded" and "over budget" in it.reason and it.cost == z + ix
    _p, code, _ = pair.clone(layout="standalone", with_content=True, budget_bytes=z + ix - 1)
    assert not (pair.i.root / "library" / s.zim.name).exists() and not pair.target_index(s.id).exists()
    # exactly content + index fits
    plan = pair.plan(layout="standalone", with_content=True, budget_bytes=z + ix)
    assert by_id(plan, s.id).action == "copy"


def test_budget_counts_index_bytes_in_shared_layout_and_skips_to_next(pair):
    big = pair.source("alpha", "a" * 1, on_target=False)
    small = pair.source("bravo", "b", on_target=False)
    # make "big" actually bigger: more pages
    pages_big = {f"A/x{i}": page_html(f"x{i}", n=20) for i in range(240)}
    s3 = pair.j.zim(name="zulu_en_2026-01.zim", pages=pages_big)
    Run(s3, "build", pair.j.emb, pair.j.settings, Log(None, echo=False)).execute()
    sizes = {"zulu_en": idx_bytes(s3), "alpha_en": idx_bytes(big), "bravo_en": idx_bytes(small)}
    assert sizes["zulu_en"] > sizes["alpha_en"]
    (pair.i.root / "config").mkdir(parents=True, exist_ok=True)
    (pair.i.root / "config" / "clone.conf").write_text("[clone]\nsources=zulu_en,alpha_en,bravo_en\n")
    budget = sizes["alpha_en"] + sizes["bravo_en"]            # not enough for zulu's index first
    plan = pair.plan(layout="shared", budget_bytes=budget)
    assert by_id(plan, "zulu_en").action == "excluded"
    assert by_id(plan, "alpha_en").action == "copy" and by_id(plan, "bravo_en").action == "copy"
    assert all(i.zim_bytes and not i.copy_zim for i in plan.items)    # ZIM bytes not charged in shared
    assert sum(i.cost for i in plan.items if i.action == "copy") <= budget


def test_fit_plan_unit():
    from prometheus_index.clone import Item
    a = Item("a", "a.zim", copy_zim=True, zim_bytes=100, index_bytes=30)
    b = Item("b", "b.zim", copy_zim=False, zim_bytes=500, index_bytes=40)
    c = Item("c", "c.zim", action="up-to-date", index_bytes=0)
    used = fit_plan([a, b, c], 120)
    assert (a.action, b.action, c.action) == ("excluded", "copy", "up-to-date") and used == 40


def test_default_budget_is_free_space_minus_headroom(pair, monkeypatch):
    pair.source("alpha", "alpha")
    monkeypatch.setattr(shutil, "disk_usage", lambda p: shutil._ntuple_diskusage(10 * GIB, 0, 3 * GIB))
    p = pair.plan(headroom_bytes=1 * GIB)
    assert p.budget == 2 * GIB and p.free == 3 * GIB


# ---- existing target index -----------------------------------------------------
def test_different_target_index_needs_replace(pair):
    s = pair.source("alpha", "alpha")
    # target index built with another model/config
    ts = Source_on(pair.i, s)
    from prometheus_index.embed import HashEmbedder
    other = HashEmbedder({"dim": 16})
    Run(ts, "build", other, pair.i.settings, Log(None, echo=False)).execute()
    assert by_id(pair.plan(), s.id).action == "skip"
    plan, code, _ = pair.clone(replace=True)
    assert code == 0 and by_id(plan, s.id).status == "copied"
    assert IndexStore(pair.target_index(s.id), readonly=True).get("sig") == config_signature(pair.j.emb)
    assert not (pair.i.root / "index" / f".{s.id}.old").exists()


def test_partial_target_build_is_replaced(pair):
    s = pair.source("alpha", "alpha")
    ts = Source_on(pair.i, s)
    with pytest.raises(SimulatedCrash):
        Run(ts, "build", pair.i.emb, pair.i.settings, Log(None, echo=False), crash_after=1).execute()
    assert inspect_index(ts.index_dir)["state"] == "incomplete"
    plan, code, _ = pair.clone()
    assert code == 0 and inspect_index(ts.index_dir)["state"] == "ready"


# ---- interrupted copy resumes; torn partial file ---------------------------------
def small_chunks(c):
    c.chunk = 256
    return c


def test_interrupted_copy_resumes_not_restarts(pair):
    s = pair.source("alpha", "alpha")
    plan = pair.plan()
    c = small_chunks(pair.cloner(plan))
    n = {"k": 0}

    def crash(_id, _b):
        n["k"] += 1
        if n["k"] == 40:
            raise SimulatedCrash()
    c.hooks["chunk"] = crash
    with pytest.raises(SimulatedCrash):
        c.run()
    cd = pair.i.root / "index" / f".{s.id}.clone"
    assert cd.is_dir() and not pair.target_index(s.id).exists()          # never looks complete
    assert json.loads((cd / ".clone.json").read_text())["verified"] is False
    assert not ops.classify(Source_on(pair.i, s), None)[0] == "up to date"
    # a half-written file with a torn tail
    parts = sorted(cd.glob("*.tmp"))
    for p in parts:
        with open(p, "ab") as f:
            f.write(b"\xde\xad" * 50)
    pair.log.lines.clear()
    plan2 = pair.plan()
    c2 = small_chunks(pair.cloner(plan2))
    assert c2.run() == 0
    assert "resuming" in pair.log.text()
    assert tree_hash(pair.target_index(s.id)) == tree_hash(s.index_dir)
    assert not cd.exists()


def test_source_changed_between_runs_restarts_clean(pair):
    s = pair.source("alpha", "alpha")
    c = small_chunks(pair.cloner(pair.plan()))
    n = {"k": 0}

    def crash(_i, _b):
        n["k"] += 1
        if n["k"] == 30:
            raise SimulatedCrash()
    c.hooks["chunk"] = crash
    with pytest.raises(SimulatedCrash):
        c.run()
    # source gets updated meanwhile (new ZIM content + update)
    z = pair.j.zim(name=s.zim.name, pages=pages("fresh", 9))
    pair.put_on_target(s)
    Run(s, "rebuild", pair.j.emb, pair.j.settings, Log(None, echo=False)).execute()
    pair.log.lines.clear()
    p2, code, _ = pair.clone()
    assert code == 0 and "discarding unusable partial clone" in pair.log.text()
    assert tree_hash(pair.target_index(s.id)) == tree_hash(s.index_dir)
    _ = z


# ---- verify catches corruption -------------------------------------------------------
def corrupt(path: Path):
    b = bytearray(path.read_bytes())
    b[len(b) // 2] ^= 0xFF
    path.write_bytes(bytes(b))


def test_verify_repairs_a_file_corrupted_once(pair):
    s = pair.source("alpha", "alpha")
    c = pair.cloner(pair.plan())
    seen = {"done": False}

    def hook(path):
        if not seen["done"] and path.name.startswith("seg-"):
            seen["done"] = True
            corrupt(path)
    c.hooks["after_copy"] = hook
    assert c.run() == 0
    assert "verify found" in pair.log.text()
    assert tree_hash(pair.target_index(s.id)) == tree_hash(s.index_dir)


def test_verify_failure_never_publishes_index(pair):
    s = pair.source("alpha", "alpha")
    c = pair.cloner(pair.plan())
    c.hooks["after_copy"] = lambda path: corrupt(path) if path.name.startswith("seg-000001") else None
    assert c.run() == 1
    it = c.plan.items[0]
    assert it.status == "failed" and "VerifyFailed" in it.detail
    assert not pair.target_index(s.id).exists()
    assert not (pair.i.root / "index" / f".{s.id}.clone").exists()       # staging removed, redo next run
    # next run (no fault) succeeds
    assert pair.clone()[1] == 0 and pair.target_index(s.id).exists()


def test_corrupt_source_is_not_propagated_and_not_modified(pair):
    s = pair.source("alpha", "alpha")
    seg = sorted(s.index_dir.glob("seg-*.vec"))[0]
    corrupt(seg)                      # same size: quick checks pass, checksum does not
    before = tree_hash(s.index_dir)
    plan, code, _ = pair.clone()
    assert code == 1 and plan.items[0].status == "failed"
    assert "SourceCorrupt" in plan.items[0].detail
    assert not pair.target_index(s.id).exists()
    assert tree_hash(s.index_dir) == before


# ---- unplugged drive -------------------------------------------------------------------
def test_unplugged_target_stops_cleanly_and_resumes_after_replug(pair, tmp_path):
    pair.source("alpha", "alpha")
    pair.source("bravo", "bravo")
    before = {x: tree_hash(Path(pair.j.root / "index" / x)) for x in ("alpha_en", "bravo_en")}
    plan = pair.plan()
    first = plan.items[0].id
    c = small_chunks(pair.cloner(plan))
    unplugged = tmp_path / "I_unplugged"
    n = {"k": 0}

    def pull(_id, _b):
        n["k"] += 1
        if n["k"] == 25:
            os.rename(pair.i.root, unplugged)       # drive vanishes mid copy
    c.hooks["chunk"] = pull
    code = c.run()
    assert code == 4
    assert [i.status for i in plan.items] == ["unplugged", "not-run"]
    assert "unplugged" in pair.log.text()
    assert not pair.i.root.exists()
    for x, h in before.items():                      # source index never touched
        assert tree_hash(pair.j.root / "index" / x) == h
    assert not (pair.j.root / "index" / f"{first}.lock").exists()   # source lock released
    os.rename(unplugged, pair.i.root)               # replug
    staging = pair.i.root / "index" / f".{first}.clone"
    assert staging.is_dir() and not pair.target_index(first).exists()
    # the lock file on the unplugged drive could not be removed; its owner (this test's
    # "previous process") is gone, which is what a real rerun sees
    lock = pair.i.root / "index" / f"{first}.lock"
    if lock.exists():
        lock.write_text(json.dumps({"host": "x", "pid": 2 ** 22 + 99, "heartbeat": 0}))
    pair.log.lines.clear()
    plan2, code2, _ = pair.clone()
    assert code2 == 0, (pair.log.text(), [(i.id, i.status, i.detail) for i in plan2.items])
    assert [i.status for i in plan2.items] == ["copied", "copied"]
    assert "resuming" in pair.log.text()
    for x in before:
        assert tree_hash(pair.target_index(x)) == tree_hash(pair.j.root / "index" / x)


def test_target_missing_at_start_is_an_error(pair, tmp_path):
    pair.source("alpha", "alpha")
    shutil.rmtree(pair.i.root)
    from prometheus_index.clone import CloneError
    with pytest.raises(CloneError, match="not found"):
        pair.plan()


# ---- pause / cancel (BAC-189 control files) -------------------------------------------------
def test_pause_then_resume(pair):
    s = pair.source("alpha", "alpha")
    plan = pair.plan()
    c = small_chunks(pair.cloner(plan))
    write_control(pair.j.root, s.id, "pause")
    out = {}
    t = threading.Thread(target=lambda: out.update(code=c.run()))
    t.start()
    j = {}
    for _ in range(200):
        p = job_path(pair.i.root, s.id)
        j = json.loads(p.read_text()) if p.exists() else {}
        if j.get("state") == "paused":
            break
        time.sleep(0.05)
    assert j.get("state") == "paused" and j.get("mode") == "clone"
    assert not pair.target_index(s.id).exists()
    write_control(pair.j.root, s.id, "resume")
    t.join(timeout=30)
    assert out.get("code") == 0 and pair.target_index(s.id).exists()


def test_pause_file_on_target_drive_also_works(pair):
    s = pair.source("alpha", "alpha")
    c = small_chunks(pair.cloner(pair.plan()))
    write_control(pair.i.root, s.id, "cancel")      # `index cancel --drive <target>` writes it there
    assert c.run() == 3
    assert c.plan.items[0].status == "cancelled"
    assert (pair.i.root / "index" / f".{s.id}.clone").is_dir()      # progress kept
    assert pair.clone()[1] == 0


def test_cancel_discard_removes_staging(pair):
    s = pair.source("alpha", "alpha")
    c = small_chunks(pair.cloner(pair.plan()))
    write_control(pair.j.root, s.id, "cancel-discard")
    assert c.run() == 3
    assert not (pair.i.root / "index" / f".{s.id}.clone").exists()
    assert not pair.target_index(s.id).exists()


def test_stop_signal_checkpoints_and_exit_130(pair):
    s = pair.source("alpha", "alpha")
    c = small_chunks(pair.cloner(pair.plan()))
    c.stopper.install = lambda: None
    c.stopper.flag = True
    assert c.run() == 130
    assert pair.clone()[1] == 0


def test_running_index_job_on_source_blocks_clone(pair):
    from prometheus_index.lockfile import SourceLock
    s = pair.source("alpha", "alpha")
    lk = SourceLock(s.lock_path)
    lk.acquire()
    try:
        plan, code, _ = pair.clone()
    finally:
        lk.release()
    assert code == 1 and plan.items[0].status == "locked"
    assert not pair.target_index(s.id).exists()


# ---- plan mode and CLI ---------------------------------------------------------------------------
def snapshot(root: Path):
    return sorted(str(p.relative_to(root)) for p in Path(root).rglob("*"))


def test_plan_mode_writes_nothing(pair, monkeypatch, capsys):
    s = pair.source("alpha", "alpha")
    pair.source("bravo", "bravo", on_target=False)
    monkeypatch.setattr(cli, "find_root", lambda *a, **k: pair.j.root)
    monkeypatch.setattr(cli, "load_settings", lambda root: pair.j.settings)
    pre_i, pre_j = snapshot(pair.i.root), snapshot(pair.j.root)
    assert cli.main(["clone", "--to", str(pair.i.root), "--plan", "--headroom-gb", "0"]) == 0
    out = capsys.readouterr().out
    assert "alpha_en" in out and "no-local-content" in out and "nothing was written" in out
    assert snapshot(pair.i.root) == pre_i and snapshot(pair.j.root) == pre_j
    assert cli.main(["clone", "--to", str(pair.i.root), "--dry-run", "--json"]) == 0
    data = json.loads(capsys.readouterr().out)
    assert {i["source"]: i["action"] for i in data["items"]} == {"alpha_en": "copy", "bravo_en": "skip"}
    _ = s


def test_cli_clone_runs_and_logs_summary(pair, monkeypatch, capsys):
    pair.source("alpha", "alpha")
    pair.source("bravo", "bravo", on_target=False)
    monkeypatch.setattr(cli, "find_root", lambda *a, **k: pair.j.root)
    monkeypatch.setattr(cli, "load_settings", lambda root: pair.j.settings)
    assert cli.main(["clone", "--to", str(pair.i.root), "--headroom-gb", "0"]) == 0
    out = capsys.readouterr().out
    assert "clone summary" in out and "copied 1" in out and "skipped 1" in out
    logs = list((pair.j.root / "run" / "logs" / "index").glob("*-clone.log"))
    assert len(logs) == 1 and "clone summary" in logs[0].read_text()
    assert pair.target_index("alpha_en").exists() and not pair.target_index("bravo_en").exists()
    # usage / bad target
    assert cli.main(["clone"]) == 2
    assert cli.main(["clone", "--to", str(pair.i.root / "nope")]) == 2
    assert cli.main(["clone", "--to", str(pair.j.root)]) == 2          # same drive


def test_cli_exit_code_4_when_unplugged(pair, monkeypatch, tmp_path):
    s = pair.source("alpha", "alpha")
    monkeypatch.setattr(cli, "find_root", lambda *a, **k: pair.j.root)
    monkeypatch.setattr(cli, "load_settings", lambda root: pair.j.settings)
    orig = Cloner._copy

    def pulled(self, it, locks, src, tmp):
        os.rename(pair.i.root, tmp_path / "gone")
        return orig(self, it, locks, src, tmp)
    monkeypatch.setattr(Cloner, "_copy", pulled)
    assert cli.main(["clone", "--to", str(pair.i.root), "--headroom-gb", "0"]) == 4
    _ = s


def test_shipped_clone_conf_is_all_defaults():
    from prometheus_index.clone import load_preset
    repo = Path(__file__).resolve().parents[2]
    p = load_preset(repo / "nonexistent-target", repo)
    assert p.sources == [] and p.layout == "auto" and p.budget_gb == 0 and p.headroom_gb == 10
