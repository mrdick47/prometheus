"""Per-source lock file on the drive (<drive>/index/<source>.lock).

No flock: exFAT shared between hosts has no reliable advisory locking. The
lock is created with O_EXCL and carries host, pid and a heartbeat. A lock is
stale when its heartbeat is older than ``stale_after`` seconds, or when it
belongs to this host and the pid is gone. Stale locks are taken over.
"""
from __future__ import annotations

import json
import os
import socket
import time
from pathlib import Path

from .fsutil import atomic_write_bytes


def hostname() -> str:
    h = os.environ.get("PROMETHEUS_HOSTNAME") or socket.gethostname()
    return h.split(".")[0]


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    if os.name == "nt":
        import ctypes

        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        k = ctypes.windll.kernel32
        h = k.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid)
        if not h:
            return False
        code = ctypes.c_ulong()
        ok = k.GetExitCodeProcess(h, ctypes.byref(code))
        k.CloseHandle(h)
        return bool(ok) and code.value == 259  # STILL_ACTIVE
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class LockBusy(Exception):
    pass


class SourceLock:
    def __init__(self, path: str | os.PathLike, stale_after: int = 21600):
        self.path = Path(path)
        self.stale_after = stale_after
        self.held = False
        self._last_beat = 0.0

    def _payload(self) -> bytes:
        return json.dumps(
            {"host": hostname(), "pid": os.getpid(), "heartbeat": time.time()}
        ).encode()

    def _read(self):
        try:
            return json.loads(self.path.read_bytes().decode())
        except (OSError, ValueError):
            return None

    def is_stale(self, info) -> bool:
        if info is None:
            return True  # unreadable / torn lock: treat as stale
        if time.time() - float(info.get("heartbeat", 0)) > self.stale_after:
            return True
        if info.get("host") == hostname() and not pid_alive(int(info.get("pid", 0))):
            return True
        return False

    def acquire(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        for _ in range(3):
            try:
                fd = os.open(str(self.path), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            except FileExistsError:
                info = self._read()
                if self.is_stale(info):
                    try:
                        os.remove(self.path)
                    except OSError:
                        pass
                    continue
                raise LockBusy(f"locked by {info.get('host')} pid {info.get('pid')}")
            with os.fdopen(fd, "wb") as f:
                f.write(self._payload())
                f.flush()
                os.fsync(f.fileno())
            self.held = True
            self._last_beat = time.time()
            return
        raise LockBusy("could not take lock")

    def heartbeat(self, min_interval: float = 5.0) -> None:
        if self.held and time.time() - self._last_beat >= min_interval:
            atomic_write_bytes(self.path, self._payload())
            self._last_beat = time.time()

    def release(self) -> None:
        if self.held:
            try:
                os.remove(self.path)
            except OSError:
                pass
            self.held = False

    def __enter__(self):
        self.acquire()
        return self

    def __exit__(self, *a):
        self.release()
