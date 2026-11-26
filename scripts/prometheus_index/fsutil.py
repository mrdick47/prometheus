"""Durable file helpers for exFAT (no symlinks, no hardlinks, no rename atomicity guarantees).

Pattern used everywhere: write a temp file in the same directory, flush,
fsync, then os.replace over the target, then fsync the directory where the OS
allows it. exFAT has no journal, so a power cut can still leave a stray temp
file or a torn rename; every reader therefore validates what it reads
(checksums / generation numbers) and every writer tolerates leftovers.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import time
from pathlib import Path

TMP_SUFFIX = ".tmp"


def fsync_dir(path: str | os.PathLike) -> None:
    """Best effort directory fsync. Windows cannot open directories; skip there."""
    if os.name == "nt":
        return
    try:
        fd = os.open(str(path), os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def replace_retry(src: str | os.PathLike, dst: str | os.PathLike, tries: int = 8) -> None:
    """os.replace with short retries (Windows AV / indexer can hold files briefly)."""
    delay = 0.05
    for i in range(tries):
        try:
            os.replace(src, dst)
            return
        except PermissionError:
            if i == tries - 1:
                raise
            time.sleep(delay)
            delay = min(delay * 2, 1.0)


def atomic_write_bytes(path: str | os.PathLike, data: bytes) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + TMP_SUFFIX)
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    replace_retry(tmp, path)
    fsync_dir(path.parent)


def atomic_write_json(path: str | os.PathLike, obj) -> None:
    atomic_write_bytes(path, json.dumps(obj, indent=1, sort_keys=True).encode("utf-8"))


def read_json(path: str | os.PathLike, default=None):
    try:
        with open(path, "rb") as f:
            return json.loads(f.read().decode("utf-8"))
    except (OSError, ValueError):
        return default


def sha256_file(path: str | os.PathLike, bufsize: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(bufsize)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def dir_size(path: str | os.PathLike) -> int:
    total = 0
    for root, _dirs, files in os.walk(path):
        for n in files:
            try:
                total += os.path.getsize(os.path.join(root, n))
            except OSError:
                pass
    return total


def rmtree_retry(path: str | os.PathLike, tries: int = 5) -> None:
    for i in range(tries):
        try:
            shutil.rmtree(path)
            return
        except FileNotFoundError:
            return
        except OSError:
            if i == tries - 1:
                raise
            time.sleep(0.2 * (i + 1))
