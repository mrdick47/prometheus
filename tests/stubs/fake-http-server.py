#!/usr/bin/env python3
"""Tiny stand-in for kiwix-serve, llamafile, or a RAG helper.

Accepts the same flag shapes the real launchers pass (--port, --address,
--host, --server, --nobrowser, -m, plus leftover ZIM paths). Behavior is
controlled with environment variables:

  STUB_ROLE       Label written to the event log (kiwix, llamafile, rag)
  STUB_EVENT_LOG  Optional path; a line is appended when the server listens
                  or when it is asked to fail.
  STUB_FAIL=1     Exit immediately without opening a port
  STUB_DELAY      Seconds to wait before binding (default 0)
  STUB_HANG=1     Sleep forever without binding (never becomes healthy)
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


def _event(message: str) -> None:
    path = os.environ.get("STUB_EVENT_LOG", "")
    if not path:
        return
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(f"{time.time():.6f} {message}\n")
        fh.flush()


def _parse(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--port", default="8080")
    parser.add_argument("--address", default="127.0.0.1")
    parser.add_argument("--host", default=None)
    parser.add_argument("--server", action="store_true")
    parser.add_argument("--nobrowser", action="store_true")
    parser.add_argument("-m", dest="model", default=None)
    parser.add_argument("--fail", action="store_true")
    args, _unknown = parser.parse_known_args(argv)
    return args


def main(argv: list[str] | None = None) -> int:
    args = _parse(argv if argv is not None else sys.argv[1:])
    role = os.environ.get("STUB_ROLE", "service")
    fail = args.fail or os.environ.get("STUB_FAIL", "") == "1"
    hang = os.environ.get("STUB_HANG", "") == "1"
    delay = float(os.environ.get("STUB_DELAY", "0") or "0")

    if fail:
        _event(f"{role} failed")
        return 1

    if delay > 0:
        time.sleep(delay)

    if hang:
        _event(f"{role} hanging")
        while True:
            time.sleep(60)

    host = args.host or args.address or "127.0.0.1"
    if host in ("0.0.0.0", "::"):
        bind_host = "0.0.0.0"
    else:
        bind_host = host
    port = int(args.port)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            if role == "llamafile" and self.path.startswith("/v1/models"):
                body = json.dumps({"object": "list", "data": [{"id": "stub-model"}]}).encode()
                content_type = "application/json"
            else:
                body = f"{role} ok\n".encode()
                content_type = "text/plain"
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt: str, *rest: object) -> None:
            return

    try:
        httpd = HTTPServer((bind_host, port), Handler)
    except OSError as exc:
        _event(f"{role} bind-failed port={port} err={exc}")
        return 1

    _event(f"{role} listening port={port}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
        _event(f"{role} stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
