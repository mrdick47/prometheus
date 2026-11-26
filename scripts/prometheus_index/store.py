"""On-disk index for one source.

    <drive>/index/<source>/
        state.db          sqlite (journal_mode=DELETE, synchronous=FULL): meta, segments, articles
        seg-NNNNNN.vec    int8 vectors, rows x dim
        seg-NNNNNN.rec    records: art_id u32, chunk u32, start u32, end u32 (little endian)

Segments are immutable and written temp+fsync+rename *before* the sqlite
transaction that registers them. The transaction is the checkpoint: it adds the
segment, upserts the article rows, advances the cursor. A crash before commit
leaves an unregistered segment file, which is deleted on the next open. A crash
after commit loses nothing. Dead rows (re-embedded or deleted articles) stay in
old segments until a rebuild; queries skip them via the article table.

No chunk text is stored: records hold byte offsets into the text extractor
output for the article at ``path`` plus the article's content hash.
"""
from __future__ import annotations

import os
import re
import sqlite3
import time
from pathlib import Path

import numpy as np

from .fsutil import atomic_write_bytes, dir_size, sha256_file

SCHEMA = 1
REC_DTYPE = np.dtype([("art", "<u4"), ("chunk", "<u4"), ("start", "<u4"), ("end", "<u4")])
SEG_RE = re.compile(r"^seg-(\d{6})\.(vec|rec)$")


class IndexCorrupt(Exception):
    pass


class IndexStore:
    def __init__(self, path: str | os.PathLike, dim: int | None = None, readonly: bool = False):
        self.path = Path(path)
        if not readonly:
            self.path.mkdir(parents=True, exist_ok=True)
        self.readonly = readonly
        if readonly:
            if not (self.path / "state.db").is_file():
                raise FileNotFoundError(self.path / "state.db")
            self.db = sqlite3.connect(f"file:{(self.path / 'state.db').as_posix()}?mode=ro",
                                      uri=True, isolation_level=None)
            self.dim = int(self.get("dim") or 0)
            return
        self.db = sqlite3.connect(str(self.path / "state.db"), isolation_level=None)
        self.db.execute("PRAGMA journal_mode=DELETE")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.executescript(
            """
            CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
            CREATE TABLE IF NOT EXISTS segments(
                seg INTEGER PRIMARY KEY, rows INTEGER, vec_sha TEXT, rec_sha TEXT);
            CREATE TABLE IF NOT EXISTS articles(
                id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT UNIQUE NOT NULL,
                hash TEXT NOT NULL, seg INTEGER, row0 INTEGER, nrows INTEGER, gen INTEGER);
            """
        )
        if dim is not None and self.get("dim") is None:
            self.set_many({"dim": str(dim), "schema": str(SCHEMA)})
        self.dim = int(self.get("dim") or dim or 0)
        self.cleanup_orphans()

    # -- meta -------------------------------------------------------------
    def get(self, k, default=None):
        r = self.db.execute("SELECT v FROM meta WHERE k=?", (k,)).fetchone()
        return r[0] if r else default

    def set_many(self, kv: dict):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            for k, v in kv.items():
                self.db.execute("INSERT OR REPLACE INTO meta(k,v) VALUES(?,?)", (k, str(v)))
            self.db.execute("COMMIT")
        except Exception:
            self.db.execute("ROLLBACK")
            raise

    def close(self):
        try:
            self.db.close()
        except Exception:
            pass

    # -- segments ---------------------------------------------------------
    def seg_paths(self, seg: int):
        return self.path / f"seg-{seg:06d}.vec", self.path / f"seg-{seg:06d}.rec"

    def next_seg(self) -> int:
        r = self.db.execute("SELECT COALESCE(MAX(seg),0) FROM segments").fetchone()[0]
        return int(r) + 1

    def cleanup_orphans(self) -> list[str]:
        """Remove segment/temp files that no committed checkpoint references."""
        known = {r[0] for r in self.db.execute("SELECT seg FROM segments")}
        removed = []
        for p in self.path.iterdir():
            m = SEG_RE.match(p.name)
            if (m and int(m.group(1)) not in known) or p.name.endswith(".tmp"):
                try:
                    p.unlink()
                    removed.append(p.name)
                except OSError:
                    pass
        return removed

    def checkpoint(self, vecs: np.ndarray, recs: np.ndarray, articles: list[tuple],
                   seen_ids: list[int], cursor: int, extra_meta: dict | None = None) -> int:
        """Commit one batch.

        articles: [(path, hash, row_offset_in_batch, nrows)] new or changed.
        seen_ids: ids of unchanged articles encountered (gen bump).
        recs['art'] holds batch-local article index until ids are assigned here.
        Returns the new segment number (0 when the batch had no chunks).
        """
        seg = 0
        gen = int(self.get("run_gen", "0"))
        vec_sha = rec_sha = ""
        nrows = int(len(vecs))
        if nrows:
            seg = self.next_seg()
            vp, rp = self.seg_paths(seg)
            # Article ids must be known before records are written: allocate them
            # inside the transaction below, but write files only after we know ids.
        self.db.execute("BEGIN IMMEDIATE")
        try:
            ids = []
            for (path, h, row0, n) in articles:
                row = self.db.execute("SELECT id FROM articles WHERE path=?", (path,)).fetchone()
                if row:
                    aid = row[0]
                    self.db.execute(
                        "UPDATE articles SET hash=?, seg=?, row0=?, nrows=?, gen=? WHERE id=?",
                        (h, seg or None, row0, n, gen, aid))
                else:
                    cur = self.db.execute(
                        "INSERT INTO articles(path,hash,seg,row0,nrows,gen) VALUES(?,?,?,?,?,?)",
                        (path, h, seg or None, row0, n, gen))
                    aid = cur.lastrowid
                ids.append(aid)
            if nrows:
                recs = recs.copy()
                recs["art"] = np.asarray(ids, dtype=np.uint32)[recs["art"]]
                vec_sha = _write_seg(vp, vecs.tobytes())
                rec_sha = _write_seg(rp, recs.tobytes())
                self.db.execute("INSERT INTO segments(seg,rows,vec_sha,rec_sha) VALUES(?,?,?,?)",
                                (seg, nrows, vec_sha, rec_sha))
            if seen_ids:
                self.db.executemany("UPDATE articles SET gen=? WHERE id=?",
                                    [(gen, i) for i in seen_ids])
            kv = {"cursor": str(cursor), "last_checkpoint": str(time.time())}
            kv.update({k: str(v) for k, v in (extra_meta or {}).items()})
            for k, v in kv.items():
                self.db.execute("INSERT OR REPLACE INTO meta(k,v) VALUES(?,?)", (k, v))
            self.db.execute("COMMIT")
        except Exception:
            self.db.execute("ROLLBACK")
            raise
        return seg

    def finish_run(self, extra_meta: dict) -> int:
        """Drop articles not seen in this run (deleted from the source). Returns count."""
        gen = int(self.get("run_gen", "0"))
        self.db.execute("BEGIN IMMEDIATE")
        try:
            n = self.db.execute("DELETE FROM articles WHERE gen < ?", (gen,)).rowcount
            kv = {"run_state": "idle", "cursor": "-1"}
            kv.update({k: str(v) for k, v in extra_meta.items()})
            for k, v in kv.items():
                self.db.execute("INSERT OR REPLACE INTO meta(k,v) VALUES(?,?)", (k, v))
            self.db.execute("COMMIT")
        except Exception:
            self.db.execute("ROLLBACK")
            raise
        return n

    def begin_run(self, resume_ok: bool = True) -> tuple[int, bool]:
        """Start or resume a run. Returns (cursor, resumed)."""
        if resume_ok and self.get("run_state") == "running":
            return int(self.get("cursor", "-1")), True
        gen = int(self.get("run_gen", "0")) + 1
        self.set_many({"run_gen": gen, "run_state": "running", "cursor": -1,
                       "run_started": time.time()})
        return -1, False

    # -- reads ------------------------------------------------------------
    def stats(self) -> dict:
        arts, alive_rows = self.db.execute(
            "SELECT COUNT(*), COALESCE(SUM(nrows),0) FROM articles").fetchone()
        total_rows = self.db.execute("SELECT COALESCE(SUM(rows),0) FROM segments").fetchone()[0]
        return {"articles": arts, "chunks": int(alive_rows), "rows_total": int(total_rows),
                "dead_rows": int(total_rows - alive_rows),
                "segments": self.db.execute("SELECT COUNT(*) FROM segments").fetchone()[0],
                "bytes": dir_size(self.path)}

    def article_by_path(self, path: str):
        return self.db.execute(
            "SELECT id,hash,seg,row0,nrows FROM articles WHERE path=?", (path,)).fetchone()

    def article_by_id(self, aid: int):
        return self.db.execute(
            "SELECT path,hash,seg FROM articles WHERE id=?", (aid,)).fetchone()

    def iter_segments(self):
        for seg, rows in self.db.execute("SELECT seg, rows FROM segments ORDER BY seg"):
            vp, rp = self.seg_paths(seg)
            vecs = np.memmap(vp, dtype=np.int8, mode="r", shape=(rows, self.dim))
            recs = np.memmap(rp, dtype=REC_DTYPE, mode="r", shape=(rows,))
            yield seg, vecs, recs

    def search(self, qvec: np.ndarray, k: int = 5) -> list[dict]:
        """Brute-force int8 dot product, skipping dead rows. qvec: float32 normalised."""
        cands: list[tuple[float, int, int]] = []  # score, seg, row
        want = max(k * 4, 32)
        recmap = {}
        for seg, vecs, recs in self.iter_segments():
            recmap[seg] = recs
            step = 65536
            for a in range(0, len(vecs), step):
                blk = np.asarray(vecs[a:a + step], dtype=np.float32)
                sc = blk @ qvec / 127.0
                top = np.argpartition(-sc, min(want, len(sc) - 1))[:want]
                cands.extend((float(sc[i]), seg, a + int(i)) for i in top)
        cands.sort(key=lambda t: -t[0])
        out = []
        seen = set()
        for score, seg, row in cands:
            rec = recmap[seg][row]
            art = self.article_by_id(int(rec["art"]))
            if art is None or art[2] != seg:
                continue  # dead row
            key = (art[0], int(rec["start"]))
            if key in seen:
                continue
            seen.add(key)
            out.append({"score": score, "path": art[0], "hash": art[1], "seg": seg, "row": row,
                        "start": int(rec["start"]), "end": int(rec["end"])})
            if len(out) >= k:
                break
        return out

    # -- integrity --------------------------------------------------------
    def verify_files(self, deep: bool = False) -> list[str]:
        """Return a list of problems (empty = intact)."""
        problems = []
        try:
            r = self.db.execute("PRAGMA quick_check").fetchone()[0]
            if r != "ok":
                problems.append(f"sqlite quick_check: {r}")
        except sqlite3.DatabaseError as e:
            return [f"sqlite error: {e}"]
        known = set()
        for seg, rows, vsha, rsha in self.db.execute(
                "SELECT seg,rows,vec_sha,rec_sha FROM segments"):
            known.add(seg)
            vp, rp = self.seg_paths(seg)
            for p, want in ((vp, rows * self.dim), (rp, rows * REC_DTYPE.itemsize)):
                if not p.exists():
                    problems.append(f"missing {p.name}")
                elif p.stat().st_size != want:
                    problems.append(f"{p.name}: size {p.stat().st_size} != expected {want}")
            if deep:
                for p, sha in ((vp, vsha), (rp, rsha)):
                    if p.exists() and sha256_file(p) != sha:
                        problems.append(f"{p.name}: checksum mismatch")
        for p in self.path.iterdir():
            m = SEG_RE.match(p.name)
            if m and int(m.group(1)) not in known:
                problems.append(f"orphan segment file {p.name}")
        bad = self.db.execute(
            "SELECT COUNT(*) FROM articles WHERE nrows>0 AND seg NOT IN (SELECT seg FROM segments)"
        ).fetchone()[0]
        if bad:
            problems.append(f"{bad} articles point at unknown segments")
        return problems


def _write_seg(path: Path, data: bytes) -> str:
    import hashlib

    atomic_write_bytes(path, data)
    return hashlib.sha256(data).hexdigest()
