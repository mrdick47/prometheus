"""index build|update|rebuild|verify|status|remove|query|pause|resume|cancel|jobs|fetch-model"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

from . import ops
from .config import discover_sources, drives_from, find_root, load_settings
from .embed import load_embedder
from .engine import (Cancelled, Interrupted, Log, Run, Stopper, config_signature,
                     write_control)

CMDS = ["build", "update", "rebuild", "verify", "status", "remove", "query", "pause",
        "resume", "cancel", "jobs", "fetch-model"]


def set_low_priority() -> None:
    try:
        if os.name == "nt":
            import ctypes
            BELOW_NORMAL = 0x00004000
            ctypes.windll.kernel32.SetPriorityClass(
                ctypes.windll.kernel32.GetCurrentProcess(), BELOW_NORMAL)
        else:
            os.nice(19)
    except Exception:
        pass


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="index", description=__doc__)
    p.add_argument("command", choices=CMDS)
    p.add_argument("args", nargs="*", help="source ids, 'all', or the query text")
    p.add_argument("--drive", action="append", default=[], metavar="PATH",
                   help="extra drive root (repeatable; also PROMETHEUS_DRIVES)")
    p.add_argument("--device", choices=["auto", "cpu", "cuda"], help="override host.conf index_device")
    p.add_argument("--model", help="embedding model dir name under models/embed/")
    p.add_argument("--max-source-gb", type=float, default=0, help="skip ZIMs larger than this")
    p.add_argument("--allow-unverified", action="store_true",
                   help="also index ZIMs without a run/verified marker (tests only)")
    p.add_argument("--priority", choices=["low", "normal"], default="low")
    p.add_argument("--yes", action="store_true", help="do not ask for confirmation (remove)")
    p.add_argument("--discard", action="store_true", help="with cancel: drop partial work")
    p.add_argument("--deep", action="store_true", help="verify: re-hash every segment")
    p.add_argument("--samples", type=int, default=5, help="verify: articles to spot-check")
    p.add_argument("-k", type=int, default=5, help="query: number of hits")
    p.add_argument("--json", action="store_true")
    p.add_argument("--no-log-file", action="store_true")
    p.add_argument("--crash-after", type=int, default=None, help=argparse.SUPPRESS)
    return p


def select(srcs, names: list[str], cmd: str, max_gb: float, log: Log, sig_state):
    want_all = not names or names == ["all"]
    out, byid = [], set(names)
    for s in sorted(srcs, key=lambda s: (s.zim.stat().st_size, s.id)):
        if not want_all and s.id not in byid:
            continue
        if s.reason:
            log.info(f"skip {s.label}: {s.reason}")
            continue
        if max_gb and s.zim.stat().st_size > max_gb * (1 << 30):
            log.info(f"skip {s.label}: ZIM {s.zim.stat().st_size / (1 << 30):.1f} GiB > "
                     f"--max-source-gb {max_gb} (queued)")
            continue
        if want_all:
            state = sig_state(s)
            if cmd == "build" and state not in ("none", "building", "failed"):
                continue
            if cmd in ("update", "rebuild") and state == "none":
                continue
        out.append(s)
    missing = byid - {s.id for s in srcs} if not want_all else set()
    for m in missing:
        log.warn(f"source not found on connected drives: {m}")
    return out


def main(argv: list[str] | None = None) -> int:
    a = parser().parse_args(argv)
    root = find_root()
    settings = load_settings(root)
    drives = drives_from(root, a.drive)
    cmd = a.command
    echo_json = a.json

    log_path = None
    if cmd in ("build", "update", "rebuild", "verify") and not a.no_log_file:
        log_path = root / "run" / "logs" / "index" / f"{time.strftime('%Y%m%d-%H%M%S')}-{cmd}.log"
    log = Log(log_path)

    if cmd == "jobs":
        js = ops.jobs(drives)
        if echo_json:
            print(json.dumps(js, indent=1))
        for j in js:
            eta = j.get("eta_sec")
            print(f"{j.get('source')}@{j.get('drive')}  {j.get('mode')}  {j.get('state')}  "
                  f"entry {j.get('entry', '-')}/{j.get('total', '-')}  "
                  f"eta {int(eta) if eta else '-'}s  pid {j.get('pid')} on {j.get('host')}")
        if not js:
            print("no jobs")
        return 0

    if cmd in ("pause", "resume", "cancel"):
        names = a.args
        if not names:
            print("usage: index pause|resume|cancel <source...>", file=sys.stderr)
            return 2
        srcs = discover_sources(drives, allow_unverified=True, settings=settings)
        n = 0
        for s in srcs:
            if s.id in names or names == ["all"]:
                action = {"cancel": "cancel-discard" if a.discard else "cancel"}.get(cmd, cmd)
                write_control(s.drive, s.id, action)
                print(f"{cmd} requested for {s.label}")
                n += 1
        return 0 if n else 1

    if cmd == "fetch-model":
        name = a.model or "bge-small-en-v1.5"
        d = ops.fetch_model(root if len(drives) == 1 else drives[0], name, log=print)
        print(f"model ready: {d}")
        return 0

    # commands that need the embedder (config signature) -------------------------
    need_emb = cmd in ("build", "update", "rebuild", "query", "verify", "status")
    emb, sig = None, None
    if need_emb:
        try:
            emb = load_embedder(drives, a.model or settings.get("model") or None,
                                device=a.device or settings.get("index_device", "auto"),
                                threads=int(settings.get("index_threads", 0) or 0))
            sig = config_signature(emb)
        except FileNotFoundError as e:
            if cmd in ("build", "update", "rebuild", "query"):
                log.error(str(e))
                return 1
            # status/verify still work without a model; they just cannot flag mismatch.

    if cmd == "status":
        print(ops.status(drives, settings, sig, as_json=echo_json))
        return 0

    srcs = discover_sources(drives, allow_unverified=a.allow_unverified, settings=settings)

    if cmd == "query":
        if not a.args:
            print("usage: index query <text> [-k N]", file=sys.stderr)
            return 2
        res = ops.query([s for s in srcs if not s.reason], emb, " ".join(a.args), k=a.k)
        if echo_json:
            print(json.dumps(res, indent=1))
        else:
            for r in res:
                flag = " [stale]" if r["stale"] else ""
                print(f"{r['score']:.3f}  {r['source']}  {r['title']!r}  {r['path']} "
                      f"@{r['start']}-{r['end']}{flag}\n        {r['snippet'][:160]!r}")
        return 0

    def state_of(s):
        return ops.classify(s, sig)[0]

    if cmd == "remove":
        targets = select(srcs, a.args, "remove", 0, log, state_of)
        if not a.args or a.args == ["all"]:
            print("remove needs an explicit source id", file=sys.stderr)
            return 2
        for s in targets:
            if not a.yes:
                ans = input(f"Delete index {s.index_dir}? [y/N] ") if sys.stdin.isatty() else "n"
                if ans.strip().lower() != "y":
                    print("kept")
                    continue
            ops.remove_index(s)
            print(f"removed {s.label}")
        return 0

    if cmd == "verify":
        targets = select(srcs, a.args, "verify", 0, log, lambda s: state_of(s))
        bad = 0
        results = []
        for s in targets:
            if state_of(s) == "none":
                continue
            r = ops.verify_source(s, sig, deep=a.deep, samples=a.samples, emb=emb)
            results.append(r)
            line = f"{s.label}: {r['state']}"
            for p in r["problems"]:
                line += f"\n    PROBLEM {p}"
            for n in r["notes"]:
                line += f"\n    note: {n}"
            if "self_retrieval" in r:
                line += f"\n    self-retrieval {r['self_retrieval']}"
            log.info(line)
            if r["state"] in ("corrupt", "failed"):
                bad += 1
            # stale / model-mismatch are reported but are not integrity failures
        # missing and orphaned
        full = discover_sources(drives, allow_unverified=True, settings=settings)
        for s in full:
            if not s.reason and state_of(s) == "none":
                log.warn(f"{s.label}: missing (no index yet)")
        if echo_json:
            print(json.dumps(results, indent=1))
        return 1 if bad else 0

    # build / update / rebuild ---------------------------------------------------
    if a.priority == "low":
        set_low_priority()
    targets = select(srcs, a.args, cmd, a.max_source_gb, log, state_of)
    if not targets:
        log.info("nothing to do")
        return 0
    stopper = Stopper()
    stopper.install()
    failed = 0
    for s in targets:
        if stopper.flag:
            break
        try:
            r = Run(s, cmd, emb, settings, log, stopper=stopper, crash_after=a.crash_after,
                    discard=a.discard).execute()
        except Exception as e:  # one bad source must not stop the rest
            log.error(f"{s.label}: failed: {type(e).__name__}: {e}")
            failed += 1
            continue
        log.info(f"result {json.dumps(r)}")
        if r.get("status") in ("interrupted",):
            return 130
        if r.get("status") == "cancelled":
            return 3
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
