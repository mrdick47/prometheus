"""Drive/host discovery. Nothing here is host- or drive-letter specific."""
from __future__ import annotations

import configparser
import os
import re
from dataclasses import dataclass, field
from pathlib import Path

from .fsutil import read_json
from .lockfile import hostname

DEFAULTS = {
    "model": "",                   # empty = first model found under models/embed/
    "index_device": "auto",        # auto | cpu | cuda   (host.conf)
    "index_threads": "0",          # 0 = onnxruntime default (host.conf)
    "checkpoint_chunks": "8192",   # chunks per checkpoint segment
    "embed_batch": "64",
    "lock_stale_after_sec": "21600",
    "defer_ocr": "survivorlibrary.com_en_all",  # scanned-PDF sources: need OCR, not indexed here
    "min_text_bytes_for_pdf": "200",  # PDFs with less text than this count as "needs OCR"
}


def find_root(start: str | os.PathLike | None = None) -> Path:
    """Drive root = parent of the scripts/ directory that holds this package."""
    here = Path(start or __file__).resolve()
    for p in [here, *here.parents]:
        if p.name == "scripts" and (p.parent / "config").is_dir():
            return p.parent
    return here.parents[2]


def _read_ini(path: Path) -> configparser.ConfigParser:
    cp = configparser.ConfigParser(inline_comment_prefixes=("#",), interpolation=None)
    cp.optionxform = str
    if path.is_file():
        cp.read(path, encoding="utf-8")
    return cp


def load_settings(root: Path) -> dict:
    """index.conf [index] overlaid by host.conf ([default] then the host's section)."""
    s = dict(DEFAULTS)
    ic = _read_ini(root / "config" / "index.conf")
    if ic.has_section("index"):
        s.update(dict(ic.items("index")))
    hc = _read_ini(root / "config" / "host.conf")
    host = hostname().lower()
    sections = ["default"] + [sec for sec in hc.sections()
                              if sec.lower().split(".")[0] == host]
    for sec in sections:
        if hc.has_section(sec):
            s.update({k: v for k, v in hc.items(sec) if k in DEFAULTS})
    return s


def drives_from(root: Path, extra: list[str] | None) -> list[Path]:
    """Own root first, then --drive / PROMETHEUS_DRIVES entries (deduplicated)."""
    out = [root]
    names = list(extra or [])
    env = os.environ.get("PROMETHEUS_DRIVES")
    if env:
        names += [x for x in env.split(os.pathsep) if x]
    for n in names:
        p = Path(n)
        if p.exists() and p.resolve() not in {d.resolve() for d in out}:
            out.append(p)
    return out


_DATE = re.compile(r"_(\d{4}-\d{2})$")


@dataclass
class Source:
    id: str                 # filename without .zim and without trailing _YYYY-MM
    drive: Path
    zim: Path
    verified: bool = False
    reason: str = ""        # why not eligible
    notes: list[str] = field(default_factory=list)

    @property
    def index_dir(self) -> Path:
        return self.drive / "index" / self.id

    @property
    def lock_path(self) -> Path:
        return self.drive / "index" / f"{self.id}.lock"

    @property
    def rebuild_dir(self) -> Path:
        return self.drive / "index" / f".{self.id}.rebuild"

    @property
    def old_dir(self) -> Path:
        return self.drive / "index" / f".{self.id}.old"

    @property
    def label(self) -> str:
        return f"{self.id}@{self.drive}"


def source_id(zim_name: str) -> str:
    stem = zim_name[:-4] if zim_name.lower().endswith(".zim") else zim_name
    return _DATE.sub("", stem)


def is_verified(drive: Path, zim: Path) -> bool:
    """A ZIM is trusted only with <drive>/run/verified/<name>.verified.json and a matching size."""
    m = read_json(drive / "run" / "verified" / (zim.name + ".verified.json"))
    if not isinstance(m, dict):
        return False
    try:
        return int(m.get("size", -1)) == zim.stat().st_size and m.get("filename", zim.name) == zim.name
    except OSError:
        return False


def discover_sources(drives: list[Path], allow_unverified: bool = False,
                     settings: dict | None = None) -> list[Source]:
    settings = settings or DEFAULTS
    defer = [x.strip() for x in settings.get("defer_ocr", "").split(",") if x.strip()]
    out: list[Source] = []
    for d in drives:
        lib = d / "library"
        if not lib.is_dir():
            continue
        for z in sorted(lib.glob("*.zim")):
            src = Source(id=source_id(z.name), drive=d, zim=z)
            src.verified = is_verified(d, z)
            if not src.verified and not allow_unverified:
                src.reason = "unverified (no matching run/verified marker)"
            elif any(src.id == x or src.id.startswith(x) for x in defer):
                src.reason = "deferred: scanned PDFs need OCR (not indexed yet)"
            out.append(src)
    return out


def source_index_dirs(drives: list[Path]) -> list[tuple[Path, str]]:
    """Existing index directories (for orphan detection)."""
    out = []
    for d in drives:
        base = d / "index"
        if base.is_dir():
            for p in sorted(base.iterdir()):
                if p.is_dir() and not p.name.startswith(".") and (p / "state.db").is_file():
                    out.append((d, p.name))
    return out
