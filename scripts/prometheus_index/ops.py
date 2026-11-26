"""status / verify / query / remove / jobs / fetch-model."""
from __future__ import annotations

import datetime
import hashlib
import json
import random
import time
import urllib.request
from pathlib import Path

from . import extract
from .config import Source, discover_sources, source_index_dirs
from .embed import Embedder, load_embedder
from .engine import config_signature, job_path
from .fsutil import atomic_write_bytes, read_json, rmtree_retry
from .lockfile import SourceLock, pid_alive
from .store import IndexStore


def _fmt_bytes(n: int) -> str:
    for u in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or u == "TiB":
            return f"{n:.0f} {u}" if u == "B" else f"{n:.1f} {u}"
        n /= 1024.0
    return str(n)


def _ts(v):
    try:
        return datetime.datetime.fromtimestamp(float(v)).strftime("%Y-%m-%d %H:%M")
    except (TypeError, ValueError):
        return "-"


def classify(src: Source, sig: str | None) -> tuple[str, dict]:
    """State of one source's index: none | up to date | stale | building | failed | model-mismatch."""
    d = src.index_dir
    info: dict = {}
    if src.rebuild_dir.is_dir():
        info["rebuilding"] = True
    if not (d / "state.db").is_file():
        return ("building" if info.get("rebuilding") else "none"), info
    try:
        st = IndexStore(d, readonly=True)
    except Exception as e:
        return "failed", {"error": str(e)}
    try:
        info.update({"model": st.get("model"), "quant": st.get("quant"),
                     "completed": st.get("completed"), "stats": st.stats(),
                     "needs_ocr_pdfs": st.get("needs_ocr_pdfs")})
        if st.get("run_state") == "running" or info.get("rebuilding"):
            return "building", info
        if st.get("completed") is None:
            return "failed", info
        if sig and st.get("sig") != sig:
            return "model-mismatch", info
        if (st.get("zim_uuid") != _zim_uuid(src.zim)) or st.get("zim_size") != str(src.zim.stat().st_size):
            return "stale", info
        return "up to date", info
    finally:
        st.close()


_uuid_cache: dict = {}


def _zim_uuid(path: Path) -> str:
    if path not in _uuid_cache:
        from libzim.reader import Archive
        _uuid_cache[path] = str(Archive(str(path)).uuid)
    return _uuid_cache[path]


def status(drives, settings, emb_sig: str | None, allow_unverified=False, as_json=False) -> str:
    rows = []
    srcs = discover_sources(drives, allow_unverified=True, settings=settings)
    for s in srcs:
        state, info = classify(s, emb_sig)
        st = info.get("stats") or {}
        note = ""
        if not s.verified:
            note = "unverified, skipped"
            if state == "none":
                state = "none (unverified)"
        elif s.reason:
            note = s.reason
        rows.append({"source": s.id, "drive": str(s.drive), "state": state,
                     "size": st.get("bytes", 0), "model": info.get("model") or "-",
                     "quant": info.get("quant") or "-", "built": _ts(info.get("completed")),
                     "articles": st.get("articles", 0), "chunks": st.get("chunks", 0),
                     "dead": st.get("dead_rows", 0), "note": note})
    present = {(str(s.drive), s.id) for s in srcs}
    for d, name in source_index_dirs(drives):
        if (str(d), name) not in present:
            rows.append({"source": name, "drive": str(d), "state": "orphaned", "size": 0,
                         "model": "-", "quant": "-", "built": "-", "articles": 0, "chunks": 0,
                         "dead": 0, "note": "index without a ZIM on this drive"})
    if as_json:
        return json.dumps(rows, indent=1)
    hdr = ["SOURCE", "DRIVE", "STATE", "SIZE", "MODEL", "QUANT", "BUILT", "ARTICLES", "CHUNKS", "NOTE"]
    table = [hdr] + [[r["source"], r["drive"], r["state"], _fmt_bytes(r["size"]) if r["size"] else "-",
                      r["model"], r["quant"], r["built"], str(r["articles"]), str(r["chunks"]),
                      r["note"]] for r in rows]
    w = [max(len(x[i]) for x in table) for i in range(len(hdr))]
    return "\n".join("  ".join(c.ljust(w[i]) for i, c in enumerate(r)).rstrip() for r in table)


def verify_source(src: Source, emb_sig: str | None, deep=False, samples=5, emb: Embedder | None = None,
                  seed: int = 0) -> dict:
    """Check one index against its source. Returns {state, problems[], notes[]}."""
    problems, notes = [], []
    state, info = classify(src, emb_sig)
    res = {"source": src.id, "drive": str(src.drive), "state": state, "problems": problems,
           "notes": notes}
    if state == "none":
        return res
    if state == "failed" and "error" in info:
        problems.append(info["error"])
        return res
    if src.rebuild_dir.exists():
        notes.append("a rebuild is in progress or was interrupted (live index unaffected)")
    st = IndexStore(src.index_dir, readonly=True)
    try:
        problems += st.verify_files(deep=deep)
        if state == "stale":
            notes.append("source ZIM changed since the index was built; run update")
        if state == "model-mismatch":
            notes.append("index was built with a different model/settings; run rebuild")
        if state == "building":
            notes.append("index build not finished")
        s = st.stats()
        if s["rows_total"] and s["dead_rows"] / s["rows_total"] > 0.3:
            notes.append(f"{s['dead_rows']}/{s['rows_total']} rows are dead; rebuild reclaims space")
        # Sample articles: ZIM entry still exists and its hash matches the stored one.
        if not problems and src.zim.exists() and samples:
            from libzim.reader import Archive
            arc = Archive(str(src.zim))
            rng = random.Random(seed)
            rows = st.db.execute("SELECT path,hash,nrows FROM articles WHERE nrows>0").fetchall()
            rng.shuffle(rows)
            checked = changed = missing = 0
            for path, h, _n in rows[:samples]:
                checked += 1
                try:
                    e = arc.get_entry_by_path(path)
                    c = bytes(e.get_item().content)
                except Exception:
                    missing += 1
                    continue
                if hashlib.sha256(c).hexdigest()[:32] != h:
                    changed += 1
            if missing:
                notes.append(f"{missing}/{checked} sampled articles no longer in the ZIM (stale)")
            if changed:
                notes.append(f"{changed}/{checked} sampled articles changed in the ZIM (stale)")
            res["sampled"] = checked
            # Self-retrieval: re-read a chunk through its offsets, re-embed it, expect it as a top hit.
            if emb is not None and not problems and rows:
                ok = tried = 0
                for path, h, _n in rows[:min(samples, 3)]:
                    hit = read_chunk(st, arc, path)
                    if hit is None:
                        continue
                    tried += 1
                    q = emb.embed([hit], is_query=False)[0]
                    top = st.search(q, k=3)
                    if any(t["path"] == path for t in top):
                        ok += 1
                res["self_retrieval"] = f"{ok}/{tried}"
                if tried and ok < tried:
                    problems.append(f"self-retrieval failed for {tried - ok}/{tried} sampled chunks")
        if problems:
            res["state"] = "corrupt"
    finally:
        st.close()
    return res


def read_chunk(st: IndexStore, arc, path: str, which: int = 0) -> str | None:
    """Read chunk text back through stored offsets (the only way text is ever obtained)."""
    row = st.article_by_path(path)
    if not row:
        return None
    aid, h, seg, row0, n = row
    if not n:
        return None
    rec = None
    for s, _v, recs in st.iter_segments():
        if s == seg:
            rec = recs[row0 + min(which, n - 1)]
            break
    if rec is None:
        return None
    e = arc.get_entry_by_path(path)
    item = e.get_item()
    text = extract.entry_to_text(item.mimetype, bytes(item.content)).encode("utf-8")
    return text[int(rec["start"]):int(rec["end"])].decode("utf-8", errors="replace")


def query(srcs: list[Source], emb: Embedder, text: str, k: int = 5) -> list[dict]:
    from libzim.reader import Archive

    q = emb.embed([text], is_query=True)[0]
    results = []
    for s in srcs:
        if not (s.index_dir / "state.db").is_file():
            continue
        st = IndexStore(s.index_dir, readonly=True)
        try:
            if st.get("model") != emb.name:
                continue
            if st.get("extractor") != extract.EXTRACTOR_VERSION:
                # offsets were computed by a different extractor: slicing would return wrong text
                print(f"warning: {s.label}: extractor mismatch, skipped (run index rebuild {s.id})",
                      file=__import__("sys").stderr)
                continue
            arc = Archive(str(s.zim))
            for h in st.search(q, k=k):
                try:
                    e = arc.get_entry_by_path(h["path"])
                    item = e.get_item()
                    full = extract.entry_to_text(item.mimetype, bytes(item.content)).encode("utf-8")
                    cur = hashlib.sha256(bytes(item.content)).hexdigest()[:32]
                    snippet = full[h["start"]:h["end"]].decode("utf-8", errors="replace")
                    title = e.title
                except Exception:
                    snippet, cur, title = "", "", ""
                results.append({**h, "source": s.id, "drive": str(s.drive), "title": title,
                                "stale": cur != h["hash"], "snippet": snippet})
        finally:
            st.close()
    results.sort(key=lambda r: -r["score"])
    return results[:k]


def remove_index(src: Source) -> bool:
    lock = SourceLock(src.lock_path)
    lock.acquire()
    try:
        for p in (src.index_dir, src.rebuild_dir, src.old_dir):
            if p.exists():
                rmtree_retry(p)
    finally:
        lock.release()
    return True


def jobs(drives: list[Path]) -> list[dict]:
    out = []
    for d in drives:
        base = d / "run" / "index-jobs"
        if not base.is_dir():
            continue
        for p in sorted(base.glob("*.json")):
            j = read_json(p)
            if not isinstance(j, dict):
                continue
            if j.get("state") in ("running", "paused") and not pid_alive(int(j.get("pid", 0))) \
                    and j.get("host") is not None:
                j["state"] = "interrupted (process gone)"
            out.append(j)
    return out


MODEL_FILES = {
    "bge-small-en-v1.5": {
        "base": "https://huggingface.co/Xenova/bge-small-en-v1.5/resolve/main/",
        "files": {"model.onnx": "onnx/model.onnx", "tokenizer.json": "tokenizer.json"},
        "sha256": {"model.onnx": "828e1496d7fabb79cfa4dcd84fa38625c0d3d21da474a00f08db0f559940cf35"},
        "embed": {"name": "bge-small-en-v1.5", "dim": 384, "pooling": "cls", "max_len": 256,
                  "query_prefix": "Represent this sentence for searching relevant passages: ",
                  "doc_prefix": "", "onnx": "model.onnx", "tokenizer": "tokenizer.json"},
    }
}


def fetch_model(drive: Path, name: str, log=print) -> Path:
    spec = MODEL_FILES[name]
    dest = drive / "models" / "embed" / name
    dest.mkdir(parents=True, exist_ok=True)
    for local, remote in spec["files"].items():
        target = dest / local
        want = spec["sha256"].get(local)
        if target.is_file() and (not want or _sha(target) == want):
            log(f"have {target}")
            continue
        tmp = dest / (local + ".part")
        log(f"downloading {remote}")
        with urllib.request.urlopen(spec["base"] + remote) as r, open(tmp, "wb") as f:
            while True:
                b = r.read(1 << 20)
                if not b:
                    break
                f.write(b)
            f.flush()
            import os
            os.fsync(f.fileno())
        if want and _sha(tmp) != want:
            tmp.unlink()
            raise RuntimeError(f"checksum mismatch for {local}")
        import os
        os.replace(tmp, target)
    atomic_write_bytes(dest / "embed.json", json.dumps(spec["embed"], indent=1).encode())
    return dest


def _sha(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()
