"""`index clone`: copy finished source indexes (and optionally their ZIMs) from one drive to another.

Standalone command for the drive-clone path, e.g. J:\\ (big drive, where the full
rebuild ran) -> I:\\ (1 TB drive). It embeds nothing. The source drive is the drive
this script lives on (or ``--from``); the target is ``--to``.

Safety rules (nothing here is host- or drive-letter specific):

* The source index is only read. Each index is copied into a staging directory
  ``<target>/index/.<id>.clone`` (files written as ``*.tmp`` then renamed, SHA-256
  recorded while reading the source), every file is re-hashed on the target, the
  copied ``state.db`` is opened and checked, and only then is the staging directory
  renamed over ``index/<id>`` (the previous index, if any, is kept until the rename
  has happened; ``engine.recover_swap`` repairs a crash in between).
* Resumable: ``<staging>/.clone.json`` records finished files and the identity of the
  source index. A re-run skips finished files, resumes a partly written file after
  comparing the bytes already there with the source, and starts over when the source
  index changed. An unplugged drive is just a crash: the run stops with exit code 4
  and the next run continues.
* Pause/resume/cancel use the BAC-189 control files (``index pause <id>``), and
  SIGINT/SIGTERM checkpoint and exit 130.
* Only content the target holds: an index is copied only when the source ZIM is on the
  target (same UUID and size), or is copied there too with ``--with-content``. In the
  ``shared`` layout (BAC-187 drive set) indexes for content that lives on the other
  drive are allowed. Index bytes always count toward the fit budget.
"""
from __future__ import annotations

import fnmatch
import hashlib
import json
import os
import shutil
import sys
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path

from .config import Source, _read_ini, discover_sources, source_id
from .engine import Cancelled, Interrupted, Log, Stopper, control_path, job_path, recover_swap
from .fsutil import (TMP_SUFFIX, atomic_write_bytes, atomic_write_json, dir_size, fsync_dir,
                     read_json, replace_retry, rmtree_retry, sha256_file)
from .lockfile import LockBusy, SourceLock, hostname
from .store import IndexStore

STATE_NAME = ".clone.json"
DRIVE_MARKER = "prometheus-drive.json"   # BAC-187 member-drive marker
GIB = 1 << 30
CHUNK = 1 << 20
LAYOUTS = ("auto", "standalone", "shared")


class CloneError(Exception):
    pass


class DriveGone(CloneError):
    """A drive root disappeared (unplugged) while cloning."""


class SourceCorrupt(CloneError):
    pass


class VerifyFailed(CloneError):
    pass


# -- options / preset ---------------------------------------------------------
@dataclass
class Options:
    src_root: Path
    dst_root: Path
    only: list[str] = field(default_factory=list)   # positional ids; empty/all = no extra filter
    plan_only: bool = False
    layout: str = "auto"
    with_content: bool = False
    budget_bytes: int = 0        # 0 = target free space minus headroom
    headroom_bytes: int | None = None
    replace: bool = False
    deep: bool = False
    discard: bool = False


@dataclass
class Preset:
    sources: list[str] = field(default_factory=list)   # allowlist in priority order; empty = all
    layout: str = "auto"
    budget_gb: float = 0.0
    headroom_gb: float = 10.0
    path: str = ""


def load_preset(dst_root: Path, src_root: Path) -> Preset:
    """``config/clone.conf`` [clone] on the target drive, else on the source drive."""
    for root in (dst_root, src_root):
        f = Path(root) / "config" / "clone.conf"
        if f.is_file():
            cp = _read_ini(f)
            if not cp.has_section("clone"):
                continue
            c = dict(cp.items("clone"))
            return Preset(
                sources=[x.strip() for x in c.get("sources", "").split(",") if x.strip()],
                layout=(c.get("layout") or "auto").strip().lower(),
                budget_gb=float(c.get("budget_gb") or 0),
                headroom_gb=float(c.get("headroom_gb") or 10),
                path=str(f))
    return Preset()


def detect_layout(src_root: Path, dst_root: Path, requested: str, preset_layout: str,
                  log: Log) -> str:
    """standalone (mirror) or shared (BAC-187 drive set). Explicit flag > preset > markers."""
    for want in (requested, preset_layout):
        if want in ("standalone", "shared"):
            return want
    a = read_json(Path(src_root) / DRIVE_MARKER)
    b = read_json(Path(dst_root) / DRIVE_MARKER)
    if isinstance(a, dict) and isinstance(b, dict) and a.get("set_id") \
            and a.get("set_id") == b.get("set_id") and a.get("drive_id") != b.get("drive_id"):
        log.info(f"layout: shared (both drives carry {DRIVE_MARKER} of set {a.get('set_id')})")
        return "shared"
    log.info(f"layout: standalone (no matching {DRIVE_MARKER} set on both drives)")
    return "standalone"


# -- inspection helpers -------------------------------------------------------
def zim_uuid(path: Path) -> str | None:
    """UUID from the 80-byte ZIM header (no libzim needed). None if not a ZIM."""
    try:
        with open(path, "rb") as f:
            h = f.read(24)
    except OSError:
        return None
    if len(h) < 24 or h[:4] != b"ZIM\x04":
        return None
    return str(uuid.UUID(bytes=h[8:24]))


def index_files(d: Path) -> list[Path]:
    """Files that make up an index; state.db last (it registers the segments)."""
    fs = [p for p in d.iterdir() if p.is_file() and not p.name.endswith(TMP_SUFFIX)
          and p.name != STATE_NAME]
    return sorted(fs, key=lambda p: (p.name == "state.db", p.name))


def inspect_index(d: Path, deep: bool = False) -> dict:
    """state: none | incomplete | corrupt | ready (+ uuid, sig, bytes, completed)."""
    out = {"state": "none", "bytes": 0}
    if not (d / "state.db").is_file():
        return out
    try:
        st = IndexStore(d, readonly=True)
    except Exception as e:
        return {"state": "corrupt", "bytes": 0, "error": str(e)}
    try:
        out.update(sig=st.get("sig"), zim_uuid=st.get("zim_uuid"), zim_size=st.get("zim_size"),
                   completed=st.get("completed"))
        if st.get("run_state") != "idle" or st.get("completed") is None:
            out["state"] = "incomplete"
        else:
            problems = st.verify_files(deep=deep)
            out["state"] = "corrupt" if problems else "ready"
            if problems:
                out["error"] = "; ".join(problems[:3])
    except Exception as e:
        out.update(state="corrupt", error=str(e))
    finally:
        st.close()
    out["bytes"] = sum(p.stat().st_size for p in index_files(d))
    return out


def _fmt(n: int) -> str:
    return f"{n / GIB:.2f} GiB" if n >= GIB else f"{n / (1 << 20):.1f} MiB"


# -- plan ---------------------------------------------------------------------
@dataclass
class Item:
    id: str
    zim_name: str
    action: str = "copy"       # copy | up-to-date | skip | excluded
    reason: str = ""
    copy_zim: bool = False
    zim_bytes: int = 0
    index_bytes: int = 0
    note: str = ""
    status: str = ""           # filled in by the run
    detail: str = ""
    bytes_copied: int = 0

    @property
    def cost(self) -> int:
        return (self.zim_bytes if self.copy_zim else 0) + self.index_bytes


@dataclass
class Plan:
    src_root: Path
    dst_root: Path
    layout: str
    with_content: bool
    budget: int
    free: int
    headroom: int
    items: list[Item]


def fit_plan(items: list[Item], budget: int) -> int:
    """Greedy fit in priority order. Content (ZIM, when it is copied) plus index bytes are
    charged together; an item that does not fit is excluded and later ones may still fit.
    Returns bytes used."""
    used = 0
    for it in items:
        if it.action != "copy":
            continue
        if used + it.cost <= budget:
            used += it.cost
        else:
            it.action = "excluded"
            content = _fmt(it.zim_bytes) if it.copy_zim else "0 (already on target)"
            it.reason = (f"over budget: content {content} + index {_fmt(it.index_bytes)} = "
                         f"{_fmt(it.cost)} > remaining {_fmt(max(budget - used, 0))}")
    return used


def _priority(patterns: list[str], sid: str) -> int:
    for i, p in enumerate(patterns):
        if fnmatch.fnmatchcase(sid, p):
            return i
    return len(patterns)


def build_plan(o: Options, log: Log, settings: dict) -> Plan:
    src_root, dst_root = Path(o.src_root), Path(o.dst_root)
    if not src_root.is_dir():
        raise CloneError(f"source drive not found: {src_root}")
    if not dst_root.is_dir():
        raise CloneError(f"target drive not found (unplugged?): {dst_root}")
    if src_root.resolve() == dst_root.resolve():
        raise CloneError("source and target are the same drive")
    preset = load_preset(dst_root, src_root)
    layout = detect_layout(src_root, dst_root, o.layout, preset.layout, log)
    if preset.path:
        log.info(f"preset: {preset.path} ({len(preset.sources)} listed sources)")
    allow = preset.sources
    srcs = discover_sources([src_root], allow_unverified=False, settings=settings)
    tgt_zims: dict[str, list[Path]] = {}
    for z in sorted((dst_root / "library").glob("*.zim")) if (dst_root / "library").is_dir() else []:
        tgt_zims.setdefault(source_id(z.name), []).append(z)

    elig = []
    for s in srcs:
        if s.reason:
            log.info(f"skip {s.id}: {s.reason}")
            continue
        if allow and _priority(allow, s.id) == len(allow):
            log.info(f"skip {s.id}: not in the target's priority preset")
            continue
        if o.only and o.only != ["all"] and s.id not in o.only:
            continue
        elig.append(s)
    elig.sort(key=lambda s: (_priority(allow, s.id) if allow else 0, s.zim.stat().st_size, s.id))

    items: list[Item] = []
    for s in elig:
        it = Item(id=s.id, zim_name=s.zim.name, zim_bytes=s.zim.stat().st_size)
        items.append(it)
        sidx = inspect_index(s.index_dir)
        it.index_bytes = sidx["bytes"]
        s_uuid = zim_uuid(s.zim)
        if sidx["state"] != "ready":
            it.action, it.reason = "skip", f"source index is {sidx['state']}" + (
                f" ({sidx['error']})" if sidx.get("error") else "")
            continue
        if sidx.get("zim_uuid") != s_uuid:
            it.action, it.reason = "skip", "source index is stale (ZIM changed since it was built); run update"
            continue
        # content on the target
        cands = tgt_zims.get(s.id, [])
        local = None
        for z in cands:
            same = zim_uuid(z) == s_uuid and z.stat().st_size == it.zim_bytes
            if same and o.deep:
                same = sha256_file(z) == sha256_file(s.zim)
            if same:
                local = z
                break
        if cands and local is None:
            it.action = "skip"
            it.reason = (f"zim-differs: target has {cands[0].name} ({zim_uuid(cands[0])}, "
                         f"{cands[0].stat().st_size} B), source has {s.zim.name} ({s_uuid}, "
                         f"{it.zim_bytes} B); not copying over it. Embed on the target instead "
                         f"(scripts/index build/rebuild) or update the ZIM first")
            continue
        if local is None:
            if o.with_content:
                it.copy_zim = True
            elif layout == "shared":
                it.note = "content stays on the other drive (shared layout); index only"
            else:
                it.action = "skip"
                it.reason = (f"no-local-content: {s.zim.name} is not on the target "
                             "(standalone layout never copies an index without its content; "
                             "use --with-content to copy the ZIM too)")
                continue
        # existing target index
        tsrc = Source(id=s.id, drive=dst_root, zim=dst_root / "library" / s.zim.name)
        tidx = inspect_index(tsrc.index_dir, deep=o.deep)
        if (tidx["state"] == "ready" and tidx.get("zim_uuid") == s_uuid
                and tidx.get("sig") == sidx.get("sig")):
            it.action, it.reason, it.index_bytes = "up-to-date", "target already has this index", 0
        elif tidx["state"] == "ready" and not o.replace:
            it.action = "skip"
            it.reason = ("target already has a different finished index "
                         "(sig/ZIM differ); use --replace to overwrite")
        elif tidx["state"] in ("ready", "corrupt", "incomplete"):
            it.note = (it.note + "; " if it.note else "") + f"replaces target index ({tidx['state']})"

    free = shutil.disk_usage(dst_root).free
    headroom = (int(o.headroom_bytes) if o.headroom_bytes is not None
                else int(preset.headroom_gb * GIB))
    credit = 0   # partial staging data from an earlier run is already on the target disk
    for it in items:
        cd = dst_root / "index" / f".{it.id}.clone"
        if it.action == "copy" and cd.is_dir():
            credit += dir_size(cd)
    if o.budget_bytes:
        budget = o.budget_bytes
    elif preset.budget_gb:
        budget = int(preset.budget_gb * GIB)
    else:
        budget = max(free - headroom, 0) + credit
    fit_plan(items, budget)
    return Plan(src_root, dst_root, layout, o.with_content, budget, free, headroom, items)


def format_plan(p: Plan) -> str:
    rows = [["SOURCE", "ACTION", "CONTENT", "INDEX", "WHY"]]
    for it in p.items:
        act = {"copy": "copy" + ("+zim" if it.copy_zim else "")}.get(it.action, it.action)
        rows.append([it.id, act, _fmt(it.zim_bytes) if it.copy_zim else "-",
                     _fmt(it.index_bytes) if it.index_bytes else "-", it.reason or it.note])
    w = [max(len(r[i]) for r in rows) for i in range(4)]
    lines = ["  ".join(c.ljust(w[i]) for i, c in enumerate(r[:4])) + "  " + r[4] for r in rows]
    used = sum(i.cost for i in p.items if i.action == "copy")
    lines.append(f"layout={p.layout} content={'copied if missing' if p.with_content else 'never copied'} "
                 f"budget={_fmt(p.budget)} planned={_fmt(used)} "
                 f"(target free {_fmt(p.free)}, headroom {_fmt(p.headroom)})")
    return "\n".join(x.rstrip() for x in lines)


# -- the run ------------------------------------------------------------------
class Cloner:
    def __init__(self, plan: Plan, settings: dict, log: Log, stopper: Stopper | None = None,
                 discard: bool = False):
        self.plan, self.settings, self.log = plan, settings, log
        self.stopper = stopper or Stopper()
        self.discard = discard
        self.chunk = CHUNK
        self.ctl_interval = 1.0
        self.stale_after = int(settings.get("lock_stale_after_sec", 21600))
        self.hooks: dict = {}          # tests: "chunk"(item_id, nbytes), "after_copy"(path)
        self._last_ctl = 0.0
        self._last_job = 0.0
        self._done_bytes = 0
        self._t0 = time.time()
        self.job: dict = {}

    # -- drives -----------------------------------------------------------
    def _gone(self) -> str | None:
        for r in (self.plan.src_root, self.plan.dst_root):
            if not Path(r).is_dir():
                return str(r)
        return None

    def _check_drives(self):
        g = self._gone()
        if g:
            raise DriveGone(g)

    # -- job / control ----------------------------------------------------
    def _job(self, it: Item, state: str, **kw):
        total = sum(i.cost for i in self.plan.items if i.action == "copy")
        self.job.update({"source": it.id, "drive": str(self.plan.dst_root), "mode": "clone",
                         "state": state, "pid": os.getpid(), "host": hostname(),
                         "updated": time.time(), "started": self._t0,
                         "bytes_done": self._done_bytes, "bytes_total": total, **kw})
        try:
            atomic_write_json(job_path(self.plan.dst_root, it.id), self.job)
        except OSError:
            pass

    def _ctl(self, it: Item) -> str | None:
        for r in (self.plan.src_root, self.plan.dst_root):
            try:
                v = control_path(Path(r), it.id).read_text(encoding="utf-8").strip()
            except OSError:
                continue
            if v:
                return v
        return None

    def _clear_ctl(self, it: Item):
        for r in (self.plan.src_root, self.plan.dst_root):
            try:
                control_path(Path(r), it.id).unlink()
            except OSError:
                pass

    def _tick(self, it: Item, fd, locks, nbytes: int):
        """Called after every chunk: hooks, stop signal, pause/cancel, job progress."""
        self._done_bytes += nbytes
        h = self.hooks.get("chunk")
        if h:
            h(it.id, self._done_bytes)
        now = time.time()
        if now - self._last_job >= 1.0:
            self._last_job = now
            self._job(it, "running")
        if not self.stopper.flag and now - self._last_ctl < self.ctl_interval:
            return
        self._last_ctl = now
        ctl = self._ctl(it)
        if not self.stopper.flag and ctl is None:
            return

        def sync():
            if fd is not None:
                try:
                    fd.flush()
                    os.fsync(fd.fileno())
                except OSError:
                    pass
        if self.stopper.flag:
            sync()
            raise Interrupted()
        if ctl.startswith("cancel"):
            sync()
            raise Cancelled(discard=ctl == "cancel-discard")
        if ctl == "pause":
            sync()
            self.log.info(f"{it.id}: clone paused")
            self._job(it, "paused")
            while True:
                time.sleep(max(min(self.ctl_interval, 1.0), 0.01))
                for lk in locks:
                    lk.heartbeat()
                if self.stopper.flag:
                    raise Interrupted()
                c2 = self._ctl(it)
                if c2 is None:
                    self.log.info(f"{it.id}: clone resumed")
                    return
                if c2.startswith("cancel"):
                    raise Cancelled(discard=c2 == "cancel-discard")

    # -- file copy --------------------------------------------------------
    def _copy(self, it: Item, locks, src: Path, tmp: Path) -> tuple[str, int]:
        """Copy src -> tmp, resuming a partial tmp after comparing it with the source.
        Returns (sha256 of the source bytes, size)."""
        size = src.stat().st_size
        h = hashlib.sha256()
        keep = 0
        if tmp.exists():
            have = tmp.stat().st_size
            with open(src, "rb") as fs, open(tmp, "r+b") as fd:
                while keep < min(have, size):
                    n = min(self.chunk, have - keep, size - keep)
                    a, b = fs.read(n), fd.read(n)
                    if a != b or len(a) != n:
                        break
                    h.update(a)
                    keep += n
                fd.truncate(keep)
                fd.flush()
                os.fsync(fd.fileno())
            if keep:
                self.log.info(f"{it.id}: resuming {src.name} at {_fmt(keep)}")
                self._done_bytes += keep
        with open(src, "rb") as fs, open(tmp, "ab" if keep else "wb") as fd:
            fs.seek(keep)
            while True:
                b = fs.read(self.chunk)
                if not b:
                    break
                fd.write(b)
                h.update(b)
                self._tick(it, fd, locks, len(b))
            fd.flush()
            os.fsync(fd.fileno())
        return h.hexdigest(), size

    # -- one source -------------------------------------------------------
    def _copy_zim(self, it: Item, locks):
        s_zim = self.plan.src_root / "library" / it.zim_name
        d_zim = self.plan.dst_root / "library" / it.zim_name
        d_zim.parent.mkdir(parents=True, exist_ok=True)
        tmp = d_zim.with_name(d_zim.name + TMP_SUFFIX)
        self.log.info(f"{it.id}: copying ZIM {it.zim_name} ({_fmt(it.zim_bytes)})")
        sha, _ = self._copy(it, locks, s_zim, tmp)
        hk = self.hooks.get("after_copy")
        if hk:
            hk(tmp)
        if sha256_file(tmp) != sha:
            rmtree_retry(tmp) if tmp.is_dir() else tmp.unlink()
            raise VerifyFailed(f"{it.zim_name}: checksum mismatch after copy; removed, rerun to redo")
        replace_retry(tmp, d_zim)
        fsync_dir(d_zim.parent)
        marker = self.plan.src_root / "run" / "verified" / (it.zim_name + ".verified.json")
        if marker.is_file():
            atomic_write_bytes(self.plan.dst_root / "run" / "verified" / marker.name,
                               marker.read_bytes())
        it.bytes_copied += it.zim_bytes

    def _seg_shas(self, sdir: Path) -> dict:
        st = IndexStore(sdir, readonly=True)
        try:
            out = {}
            for seg, _rows, vsha, rsha in st.db.execute("SELECT seg,rows,vec_sha,rec_sha FROM segments"):
                out[f"seg-{seg:06d}.vec"] = vsha
                out[f"seg-{seg:06d}.rec"] = rsha
            return out
        finally:
            st.close()

    def _copy_index(self, it: Item, locks, s_src: Source, d_src: Source):
        log = self.log
        sdir, cdir = s_src.index_dir, d_src.clone_dir
        now = inspect_index(sdir)
        if now["state"] != "ready":
            raise SourceCorrupt(f"source index is {now['state']}: {now.get('error', '')}")
        files = index_files(sdir)
        ident = {"zim_uuid": now.get("zim_uuid"), "sig": now.get("sig"),
                 "completed": now.get("completed"),
                 "files": {p.name: [p.stat().st_size, p.stat().st_mtime_ns] for p in files}}
        state = read_json(cdir / STATE_NAME) if cdir.is_dir() else None
        if cdir.is_dir() and (self.discard or not state or state.get("ident") != ident):
            log.info(f"{it.id}: discarding unusable partial clone ({'--discard' if self.discard else 'source changed or no state'})")
            rmtree_retry(cdir)
            state = None
        cdir.mkdir(parents=True, exist_ok=True)
        if state is None:
            state = {"version": 1, "ident": ident, "files": {}, "verified": False,
                     "layout": self.plan.layout, "started": time.time(),
                     "source_host": hostname()}
            atomic_write_json(cdir / STATE_NAME, state)
        elif state.get("files"):
            log.info(f"{it.id}: resuming clone, {len(state['files'])}/{len(files)} files already copied")
        seg_sha = self._seg_shas(sdir)

        def copy_missing():
            for p in files:
                rec = state["files"].get(p.name)
                dst = cdir / p.name
                if rec and dst.is_file() and dst.stat().st_size == rec["size"]:
                    continue
                sha, size = self._copy(it, locks, p, cdir / (p.name + TMP_SUFFIX))
                if p.name in seg_sha and sha != seg_sha[p.name]:
                    raise SourceCorrupt(f"source {p.name} does not match its recorded checksum; "
                                        "not copying a damaged index")
                hk = self.hooks.get("after_copy")
                if hk:
                    hk(cdir / (p.name + TMP_SUFFIX))
                replace_retry(cdir / (p.name + TMP_SUFFIX), dst)
                state["files"][p.name] = {"size": size, "sha256": sha}
                atomic_write_json(cdir / STATE_NAME, state)

        copy_missing()
        problems = self._verify(cdir, state, now)
        if problems:
            log.warn(f"{it.id}: verify found {len(problems)} problem(s): {problems[:3]}; recopying bad files once")
            for name in list(state["files"]):
                path = cdir / name
                bad = (not path.is_file() or path.stat().st_size != state["files"][name]["size"]
                       or sha256_file(path) != state["files"][name]["sha256"])
                if bad:
                    try:
                        path.unlink()
                    except OSError:
                        pass
                    del state["files"][name]
            atomic_write_json(cdir / STATE_NAME, state)
            copy_missing()
            problems = self._verify(cdir, state, now)
            if problems:
                rmtree_retry(cdir)
                raise VerifyFailed("; ".join(problems[:5]) + " (staging removed; rerun to redo)")
        state["verified"] = True
        state["verified_at"] = time.time()
        atomic_write_json(cdir / STATE_NAME, state)
        recover_swap(d_src, log)
        self._swap(d_src)
        it.bytes_copied += it.index_bytes
        log.info(f"{it.id}: index copied and verified ({_fmt(it.index_bytes)}, {len(files)} files)")

    def _verify(self, cdir: Path, state: dict, now: dict) -> list[str]:
        problems = []
        for name, rec in state["files"].items():
            p = cdir / name
            if not p.is_file():
                problems.append(f"missing {name}")
            elif p.stat().st_size != rec["size"]:
                problems.append(f"{name}: size {p.stat().st_size} != {rec['size']}")
            elif sha256_file(p) != rec["sha256"]:
                problems.append(f"{name}: checksum mismatch")
        want = set(state["ident"]["files"])
        if want - set(state["files"]):
            problems.append(f"incomplete: {sorted(want - set(state['files']))[:3]} not copied")
        if not problems:
            for p in cdir.iterdir():
                if p.is_file() and p.name not in want and p.name != STATE_NAME:
                    problems.append(f"unexpected file {p.name}")
        if not problems:
            r = inspect_index(cdir)
            if r["state"] != "ready":
                problems.append(f"copied index is {r['state']}: {r.get('error', '')}")
            elif r.get("zim_uuid") != now.get("zim_uuid") or r.get("sig") != now.get("sig"):
                problems.append("copied index metadata differs from the source")
        return problems

    def _swap(self, d: Source):
        live, new, old = d.index_dir, d.clone_dir, d.old_dir
        if old.exists():
            rmtree_retry(old)
        if live.exists():
            replace_retry(live, old)
            fsync_dir(live.parent)
        replace_retry(new, live)
        fsync_dir(live.parent)
        if old.exists():
            rmtree_retry(old)

    def _one(self, it: Item) -> None:
        p = self.plan
        s_src = Source(id=it.id, drive=p.src_root, zim=p.src_root / "library" / it.zim_name)
        d_src = Source(id=it.id, drive=p.dst_root, zim=p.dst_root / "library" / it.zim_name)
        (p.dst_root / "index").mkdir(parents=True, exist_ok=True)
        locks = []
        try:
            for s in (s_src, d_src):
                lk = SourceLock(s.lock_path, self.stale_after)
                lk.acquire()
                locks.append(lk)
        except LockBusy as e:
            for lk in locks:
                lk.release()
            it.status, it.detail = "locked", str(e)
            self.log.warn(f"{it.id}: skipped, {e} (is an index job still running on it?)")
            return
        try:
            self._job(it, "running")
            if it.copy_zim:
                self._copy_zim(it, locks)
            self._copy_index(it, locks, s_src, d_src)
            it.status = "copied"
            self._job(it, "done")
        finally:
            for lk in locks:
                lk.release()

    def run(self) -> int:
        """Execute the plan. Exit code: 0 ok, 1 a source failed or was locked, 3 cancelled,
        4 a drive was unplugged, 130 interrupted. A failed source does not stop the others;
        unplug, cancel and interrupt stop the run."""
        log, p = self.log, self.plan
        stop = 0
        self.stopper.install()
        try:
            for it in p.items:
                if it.action != "copy":
                    it.status = {"skip": "skipped", "excluded": "excluded",
                                 "up-to-date": "up-to-date"}[it.action]
                    it.detail = it.reason
                    continue
                if stop:
                    it.status, it.detail = "not-run", "run stopped earlier"
                    continue
                try:
                    self._check_drives()
                    self._one(it)
                except DriveGone as e:
                    it.status, it.detail = "unplugged", f"drive not reachable: {e}"
                    log.error(f"{it.id}: drive {e} disappeared (unplugged?). Partial copy kept as "
                              "staging only; replug and rerun to resume")
                    stop = 4
                except Interrupted:
                    it.status, it.detail = "interrupted", "progress saved; rerun to resume"
                    self._job(it, "interrupted")
                    log.warn(f"{it.id}: interrupted; rerun to resume")
                    stop = 130
                except Cancelled as c:
                    self._clear_ctl(it)
                    if c.discard:
                        rmtree_retry(p.dst_root / "index" / f".{it.id}.clone")
                    it.status = "cancelled"
                    it.detail = "partial work discarded" if c.discard else "progress kept; rerun to resume"
                    self._job(it, "cancelled", discarded=c.discard)
                    log.warn(f"{it.id}: cancelled, {it.detail}")
                    stop = 3
                except (SourceCorrupt, VerifyFailed) as e:
                    it.status, it.detail = "failed", f"{type(e).__name__}: {e}"
                    self._job(it, "failed", error=str(e))
                    log.error(f"{it.id}: {it.detail}")
                except OSError as e:
                    g = self._gone()
                    if g:
                        it.status, it.detail = "unplugged", f"drive not reachable: {g}"
                        log.error(f"{it.id}: drive {g} disappeared during copy ({e}). Replug and "
                                  "rerun to resume")
                        stop = 4
                    else:
                        it.status, it.detail = "failed", f"{type(e).__name__}: {e}"
                        log.error(f"{it.id}: {it.detail}")
        finally:
            self.stopper.restore()
        if stop:
            return stop
        return 1 if any(i.status in ("failed", "locked") for i in p.items) else 0


def summary(plan: Plan, items: list[Item], code: int) -> str:
    n = lambda *st: [i for i in items if i.status in st]  # noqa: E731
    lines = [f"clone summary: layout={plan.layout} from={plan.src_root} to={plan.dst_root} "
             f"content={'copied if missing' if plan.with_content else 'never copied'}"]
    for i in items:
        extra = f" ({i.detail})" if i.detail else ""
        lines.append(f"  [{i.status or i.action}] {i.id}: index {_fmt(i.index_bytes)}"
                     + (f" + zim {_fmt(i.zim_bytes)}" if i.copy_zim else "") + extra)
    lines.append(f"  copied {len(n('copied'))} ({_fmt(sum(i.bytes_copied for i in items))}), "
                 f"up-to-date {len(n('up-to-date'))}, skipped {len(n('skipped'))}, "
                 f"excluded {len(n('excluded'))}, failed {len(n('failed'))}, "
                 f"locked {len(n('locked'))}, other {len(n('unplugged', 'interrupted', 'cancelled', 'not-run'))}; "
                 f"exit {code}")
    return "\n".join(lines)


def run_cli(a, root: Path, settings: dict, log: Log) -> int:
    if not a.to:
        print("usage: index clone --to <target drive root> [--from <source drive root>] "
              "[--plan] [--with-content] [--layout auto|standalone|shared] [source ...]",
              file=sys.stderr)
        return 2
    if a.json:
        log.echo = False   # keep stdout pure JSON; the log file still gets everything
    o = Options(src_root=Path(a.src_drive) if a.src_drive else root, dst_root=Path(a.to),
                only=list(a.args), plan_only=a.plan, layout=a.layout, with_content=a.with_content,
                budget_bytes=int(a.budget_gb * GIB) if a.budget_gb else 0,
                headroom_bytes=int(a.headroom_gb * GIB) if a.headroom_gb is not None else None,
                replace=a.replace, deep=a.deep, discard=a.discard)
    try:
        plan = build_plan(o, log, settings)
    except CloneError as e:
        log.error(str(e))
        return 2
    if a.json and o.plan_only:
        print(json.dumps({"layout": plan.layout, "budget": plan.budget, "free": plan.free,
                          "items": [{"source": i.id, "action": i.action, "reason": i.reason,
                                     "copy_zim": i.copy_zim, "zim_bytes": i.zim_bytes,
                                     "index_bytes": i.index_bytes, "cost": i.cost}
                                    for i in plan.items]}, indent=1))
        return 0
    log.info("clone plan:\n" + format_plan(plan))
    if o.plan_only:
        log.info("plan only (--plan): nothing was written")
        return 0
    c = Cloner(plan, settings, log, discard=o.discard)
    code = c.run()
    log.info(summary(plan, plan.items, code))
    if a.json:
        print(json.dumps([{"source": i.id, "status": i.status, "detail": i.detail,
                           "bytes": i.bytes_copied} for i in plan.items], indent=1))
    return code

