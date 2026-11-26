"""build / update / rebuild engine for one source on one drive."""
from __future__ import annotations

import hashlib
import os
import shutil
import signal
import time
from pathlib import Path

import numpy as np

from . import extract
from .config import Source
from .embed import QUANT, Embedder, quantize_int8
from .fsutil import atomic_write_json, fsync_dir, read_json, replace_retry, rmtree_retry
from .lockfile import LockBusy, SourceLock, hostname
from .store import REC_DTYPE, IndexStore


def entry_getter(arc):
    """libzim 3.x names it _get_entry_by_id, 4.x get_entry_by_id."""
    return getattr(arc, "get_entry_by_id", None) or arc._get_entry_by_id


class TooManyErrors(RuntimeError):
    pass


class Interrupted(Exception):
    """SIGINT/SIGTERM: progress was checkpointed, run can resume."""


class Cancelled(Exception):
    def __init__(self, discard: bool = False):
        super().__init__("cancelled")
        self.discard = discard


class SimulatedCrash(BaseException):
    """Test hook: dies without any cleanup, like a power cut."""


class Log:
    def __init__(self, path: Path | None, echo: bool = True):
        self.path = path
        self.echo = echo
        if path:
            path.parent.mkdir(parents=True, exist_ok=True)

    def _w(self, level, msg):
        line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [{level}] {msg}"
        if self.echo:
            print(line, flush=True)
        if self.path:
            try:
                with open(self.path, "a", encoding="utf-8") as f:
                    f.write(line + "\n")
            except OSError:
                pass

    def info(self, m): self._w("INFO", m)
    def warn(self, m): self._w("WARN", m)
    def error(self, m): self._w("ERROR", m)


def config_signature(emb: Embedder, chunk_max: int = extract.CHUNK_MAX_BYTES) -> str:
    return "|".join([emb.name, emb.fingerprint, str(emb.dim), QUANT,
                     extract.EXTRACTOR_VERSION, f"chunk{chunk_max}"])


# -- control (pause / resume / cancel) -----------------------------------------
def control_path(drive: Path, source_id: str) -> Path:
    return drive / "run" / "index-control" / f"{source_id}.ctl"


def write_control(drive: Path, source_id: str, action: str) -> Path:
    p = control_path(drive, source_id)
    p.parent.mkdir(parents=True, exist_ok=True)
    if action == "resume":
        if p.exists():
            p.unlink()
        return p
    p.write_text(action, encoding="utf-8")
    return p


def job_path(drive: Path, source_id: str) -> Path:
    return drive / "run" / "index-jobs" / f"{source_id}.json"


class Stopper:
    """Turns SIGINT/SIGTERM into a flag checked at checkpoint boundaries."""

    def __init__(self):
        self.flag = False
        self._old = {}

    def install(self):
        for s in (signal.SIGINT, signal.SIGTERM):
            try:
                self._old[s] = signal.signal(s, self._h)
            except (ValueError, OSError):
                pass

    def restore(self):
        for s, h in self._old.items():
            try:
                signal.signal(s, h)
            except (ValueError, OSError):
                pass

    def _h(self, *_a):
        self.flag = True


# -- swap-in for rebuilds ------------------------------------------------------
def recover_swap(src: Source, log: Log) -> None:
    """Finish or undo a rebuild swap that a crash interrupted."""
    live, new, old = src.index_dir, src.rebuild_dir, src.old_dir
    if not live.exists():
        if new.is_dir() and _is_complete(new):
            log.warn(f"{src.id}: finishing interrupted swap (new -> live)")
            replace_retry(new, live)
        elif old.is_dir():
            log.warn(f"{src.id}: restoring previous index after interrupted swap")
            replace_retry(old, live)
        fsync_dir(live.parent)
    if live.exists() and old.exists():
        rmtree_retry(old)


def _is_complete(d: Path) -> bool:
    try:
        st = IndexStore(d, readonly=True)
    except Exception:
        return False
    try:
        return st.get("run_state") == "idle" and st.get("completed") is not None
    finally:
        st.close()


def swap_in(src: Source) -> None:
    live, new, old = src.index_dir, src.rebuild_dir, src.old_dir
    if old.exists():
        rmtree_retry(old)
    if live.exists():
        replace_retry(live, old)
        fsync_dir(live.parent)
    replace_retry(new, live)
    fsync_dir(live.parent)
    if old.exists():
        rmtree_retry(old)


# -- the run -------------------------------------------------------------------
class Run:
    def __init__(self, src: Source, mode: str, emb: Embedder, settings: dict, log: Log,
                 stopper: Stopper | None = None, crash_after: int | None = None,
                 discard: bool = False):
        self.src, self.mode, self.emb, self.settings, self.log = src, mode, emb, settings, log
        self.stopper = stopper or Stopper()
        self.crash_after = crash_after
        self.checkpoints = 0
        self.ck_chunks = int(settings.get("checkpoint_chunks", 8192))
        self.batch = int(settings.get("embed_batch", 64))
        self.min_pdf = int(settings.get("min_text_bytes_for_pdf", 200))
        self.stale_after = int(settings.get("lock_stale_after_sec", 21600))
        self.job: dict = {}
        self.t0 = time.time()
        self.discard = discard

    # progress file (the "job list" entry) ---------------------------------
    def _job(self, state: str, **kw):
        self.job.update({"source": self.src.id, "drive": str(self.src.drive), "mode": self.mode,
                         "state": state, "pid": os.getpid(), "host": hostname(),
                         "updated": time.time(), "started": self.t0, **kw})
        try:
            atomic_write_json(job_path(self.src.drive, self.src.id), self.job)
        except OSError:
            pass

    def _poll_control(self) -> str | None:
        p = control_path(self.src.drive, self.src.id)
        try:
            return p.read_text(encoding="utf-8").strip() or None
        except OSError:
            return None

    def execute(self) -> dict:
        src, log = self.src, self.log
        src.index_dir.parent.mkdir(parents=True, exist_ok=True)
        recover_swap(src, log)
        lock = SourceLock(src.lock_path, self.stale_after)
        try:
            lock.acquire()
        except LockBusy as e:
            log.warn(f"{src.label}: skipped, {e}")
            return {"source": src.id, "drive": str(src.drive), "status": "locked", "detail": str(e)}
        try:
            return self._execute_locked(lock)
        finally:
            lock.release()

    def _execute_locked(self, lock: SourceLock) -> dict:
        src, log, emb, mode = self.src, self.log, self.emb, self.mode
        sig = config_signature(emb)
        live_exists = (src.index_dir / "state.db").is_file()
        target = src.index_dir
        res = {"source": src.id, "drive": str(src.drive), "mode": mode}

        if mode == "rebuild":
            target = src.rebuild_dir
            if target.exists():
                st = IndexStore(target, readonly=True) if (target / "state.db").is_file() else None
                same = st is not None and st.get("sig") == sig
                if st:
                    st.close()
                if not same or self.discard:
                    log.info(f"{src.id}: discarding stale partial rebuild")
                    rmtree_retry(target)
        elif mode == "update":
            if not live_exists:
                return {**res, "status": "missing", "detail": "no index; run build"}
        elif mode == "build" and live_exists:
            st = IndexStore(src.index_dir, readonly=True)
            done = st.get("run_state") == "idle" and st.get("completed") is not None
            msig = st.get("sig")
            st.close()
            if done:
                return {**res, "status": "exists",
                        "detail": "index already built (use update or rebuild)"
                        + ("" if msig == sig else "; model/config mismatch, use rebuild")}
        store = IndexStore(target, dim=emb.dim)
        try:
            if store.get("sig") not in (None, sig):
                if mode == "update":
                    return {**res, "status": "model-mismatch",
                            "detail": "index built with different model/settings; run rebuild"}
                if mode == "build":  # partial index with other settings: start over
                    store.close()
                    rmtree_retry(target)
                    store = IndexStore(target, dim=emb.dim)
            if store.get("sig") is None:
                store.set_many({"sig": sig, "model": emb.name, "dim": emb.dim, "quant": QUANT,
                                "extractor": extract.EXTRACTOR_VERSION,
                                "chunk_max_bytes": extract.CHUNK_MAX_BYTES,
                                "source": src.id, "zim_filename": src.zim.name,
                                "created": time.time()})
            return {**res, **self._index(store, lock, target, sig)}
        except Interrupted:
            self._job("interrupted")
            log.warn(f"{src.label}: interrupted; progress checkpointed, rerun to resume")
            return {**res, "status": "interrupted"}
        except Cancelled as c:
            return {**res, **self._cancel(store, target, c.discard)}
        finally:
            store.close()

    def _cancel(self, store: IndexStore, target: Path, discard: bool) -> dict:
        src = self.src
        try:
            control_path(src.drive, src.id).unlink()
        except OSError:
            pass
        if discard:
            had_completed = store.get("completed") is not None
            store.close()
            if self.mode == "rebuild" or not had_completed:
                rmtree_retry(target)
                self.log.warn(f"{src.label}: cancelled, partial work discarded")
            else:
                s2 = IndexStore(target)
                s2.set_many({"run_state": "idle"})
                s2.close()
                self.log.warn(f"{src.label}: cancelled, run state reset (committed data kept)")
            self._job("cancelled", discarded=True)
            return {"status": "cancelled", "discarded": True}
        self._job("cancelled", discarded=False)
        self.log.warn(f"{src.label}: cancelled, progress kept; rerun to resume")
        return {"status": "cancelled", "discarded": False}

    # ------------------------------------------------------------------
    def _index(self, store: IndexStore, lock: SourceLock, target: Path, sig: str) -> dict:
        from libzim.reader import Archive

        src, log, emb = self.src, self.log, self.emb
        arc = Archive(str(src.zim))
        zim_id = {"zim_uuid": str(arc.uuid), "zim_size": src.zim.stat().st_size,
                  "zim_filename": src.zim.name}
        total = arc.all_entry_count
        get_entry = entry_getter(arc)
        consec_err = 0

        # Fast path: unchanged source and finished index.
        if (self.mode == "update" and store.get("run_state") == "idle"
                and store.get("zim_uuid") == zim_id["zim_uuid"]
                and store.get("zim_size") == str(zim_id["zim_size"])
                and store.get("completed") is not None
                and int(store.get("errors", "0") or 0) == 0):
            log.info(f"{src.label}: up to date (same ZIM {zim_id['zim_uuid']}), nothing to embed")
            return {"status": "up-to-date", **store.stats()}

        same_zim = store.get("run_zim") == zim_id["zim_uuid"]
        cursor, resumed = store.begin_run(resume_ok=same_zim)
        store.set_many({"run_zim": zim_id["zim_uuid"]})
        if resumed:
            log.info(f"{src.label}: resuming at entry {cursor + 1}/{total}")
        else:
            log.info(f"{src.label}: starting {self.mode} over {total} entries "
                     f"(model {emb.name}, device {emb.device})")

        pending: list[tuple[str, str, list[str], list[tuple[int, int]]]] = []
        seen: list[int] = []
        pend_chunks = 0
        counters = {"embedded_articles": 0, "unchanged": 0, "skipped_nontext": 0,
                    "errors": 0, "needs_ocr_pdfs": 0}
        t_start = time.time()
        last_ctl = 0.0

        def progress(i, state="running"):
            el = max(time.time() - t_start, 1e-6)
            done = i - cursor
            eta = (total - i - 1) * el / done if done > 0 else None
            self._job(state, entry=i, total=total, eta_sec=eta, counters=dict(counters),
                      cursor=i, chunks=store.stats()["chunks"] if state != "running" else None)

        def flush(i: int):
            nonlocal pending, seen, pend_chunks
            texts = [t for (_p, _h, ts, _o) in pending for t in ts]
            vecs = np.zeros((0, emb.dim), dtype=np.int8)
            if texts:
                order = sorted(range(len(texts)), key=lambda k: len(texts[k]))
                out = np.zeros((len(texts), emb.dim), dtype=np.int8)
                for a in range(0, len(order), self.batch):
                    idx = order[a:a + self.batch]
                    out[idx] = quantize_int8(emb.embed([texts[k] for k in idx]))
                vecs = out
            recs = np.zeros(len(texts), dtype=REC_DTYPE)
            arts, row = [], 0
            for ai, (path, h, ts, offs) in enumerate(pending):
                for ci, (s, e) in enumerate(offs):
                    recs[row + ci] = (ai, ci, s, e)
                arts.append((path, h, row, len(ts)))
                row += len(ts)
            store.checkpoint(vecs, recs, arts, seen, i, extra_meta={"state_note": "checkpoint"})
            self.checkpoints += 1
            pending, seen, pend_chunks = [], [], 0
            lock.heartbeat()
            progress(i)
            if self.crash_after is not None and self.checkpoints >= self.crash_after:
                raise SimulatedCrash()

        def boundary(i: int):
            nonlocal last_ctl
            if self.stopper.flag:
                flush(i)
                raise Interrupted()
            now = time.time()
            if now - last_ctl < 1.0:
                return
            last_ctl = now
            ctl = self._poll_control()
            if ctl is None:
                return
            if ctl.startswith("cancel"):
                flush(i)
                raise Cancelled(discard=ctl == "cancel-discard")
            if ctl == "pause":
                flush(i)
                log.info(f"{src.label}: paused at entry {i}")
                self._job("paused", entry=i, total=total)
                while True:
                    time.sleep(1.0)
                    lock.heartbeat()
                    if self.stopper.flag:
                        raise Interrupted()
                    c2 = self._poll_control()
                    if c2 is None:
                        log.info(f"{src.label}: resumed")
                        return
                    if c2.startswith("cancel"):
                        raise Cancelled(discard=c2 == "cancel-discard")

        i = cursor
        for i in range(cursor + 1, total):
            boundary(i - 1)
            try:
                entry = get_entry(i)
                consec_err = 0
                if entry.is_redirect:
                    continue
                item = entry.get_item()
                mt = item.mimetype
                if not extract.is_indexable(mt):
                    counters["skipped_nontext"] += 1
                    continue
                content = bytes(item.content)
                h = hashlib.sha256(content).hexdigest()[:32]
                path = entry.path
                row = store.article_by_path(path)
                if row and row[1] == h:
                    seen.append(row[0])
                    counters["unchanged"] += 1
                    if len(seen) >= 20000:
                        flush(i)
                    continue
                text = extract.entry_to_text(mt, content)
                tb = text.encode("utf-8")
                if mt.startswith("application/pdf") and len(tb) < self.min_pdf:
                    counters["needs_ocr_pdfs"] += 1
                    log.warn(f"{src.id}: {path}: no text layer (needs OCR), recorded without chunks")
                offs = extract.chunk_offsets(tb)
                chunks = [tb[s:e].decode("utf-8") for s, e in offs]
                pending.append((path, h, chunks, offs))
                pend_chunks += len(chunks)
                counters["embedded_articles"] += 1
            except (SimulatedCrash, Interrupted, Cancelled):
                raise
            except Exception as ex:  # unreadable entry: log, count, continue
                counters["errors"] += 1
                consec_err += 1
                log.warn(f"{src.id}: skip entry {i}: {type(ex).__name__}: {ex}")
                if consec_err >= 50:   # systematic failure, not a few bad entries
                    flush(i)
                    raise TooManyErrors(f"{consec_err} consecutive entry errors; last: {ex}")
                continue
            if pend_chunks >= self.ck_chunks:
                flush(i)
        flush(total - 1 if total else -1)
        deleted = store.finish_run({**{k: str(v) for k, v in zim_id.items()},
                                    "completed": time.time(),
                                    "skipped_nontext": counters["skipped_nontext"],
                                    "needs_ocr_pdfs": counters["needs_ocr_pdfs"],
                                    "errors": counters["errors"], "device": emb.device})
        stats = store.stats()
        log.info(f"{src.label}: done. {counters['embedded_articles']} embedded, "
                 f"{counters['unchanged']} unchanged, {deleted} removed, "
                 f"{counters['skipped_nontext']} non-text skipped, {counters['errors']} errors; "
                 f"{stats['articles']} articles / {stats['chunks']} chunks")
        store.close()
        if self.mode == "rebuild":
            swap_in(src)
            log.info(f"{src.label}: rebuild swapped in")
        self._job("done", entry=total - 1, total=total, counters=counters)
        return {"status": "ok", "removed": deleted, **counters, **stats}
