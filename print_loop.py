#!/usr/bin/env python3
"""
Local Bambu LAN MQTT subscriber + HTTP print.json for PrintGlance.

  GET /print.json
  GET /health

Read-only MQTT (no pause/stop/print).
"""

from __future__ import annotations

import json
import logging
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlparse

from bambu import BambuSnapshot, config_from_env, make_client

log = logging.getLogger("print-loop")

HOST = os.environ.get("PRINT_HOST", os.environ.get("HOST", "0.0.0.0"))
PORT = int(os.environ.get("PRINT_PORT", os.environ.get("PORT", "8080")))
STATS_TOKEN = (os.environ.get("STATS_TOKEN") or "").strip()

_snap_obj: BambuSnapshot | None = None
_lock = threading.Lock()


_EMPTY_PRINT = b'{"v":1,"updated_at":null,"focus_id":null,"printers":[]}'


def _snap() -> BambuSnapshot | None:
    with _lock:
        return _snap_obj


class Handler(BaseHTTPRequestHandler):
    server_version = "PrintGlance-feed/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        log.info("%s - %s", self.address_string(), fmt % args)

    def _token_ok(self) -> bool:
        if not STATS_TOKEN:
            return True
        return self.headers.get("X-Stats-Token") == STATS_TOKEN

    def _send(self, code: int, body: bytes, content_type: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path == "/health":
            snap = _snap()
            payload = {
                "ok": True,
                "updated_at": snap.last_report_iso() if snap else None,
                "token_required": bool(STATS_TOKEN),
            }
            self._send(200, json.dumps(payload).encode("utf-8"), "application/json")
            return

        if path in ("/print.json", "/print"):
            if STATS_TOKEN and not self._token_ok():
                self._send(401, b'{"error":"unauthorized"}', "application/json")
                return
            snap = _snap()
            body = snap.print_json_bytes() if snap else _EMPTY_PRINT
            self._send(200, body, "application/json")
            return

        if path == "/":
            self._send(
                200,
                b'{"service":"PrintGlance","endpoints":["/print.json","/health"]}',
                "application/json",
            )
            return

        self._send(404, b'{"error":"not found"}', "application/json")


def main() -> int:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    ip, serial, code, name = config_from_env()
    snap = BambuSnapshot("x2d", name)
    global _snap_obj
    with _lock:
        _snap_obj = snap

    client = make_client(ip, serial, code, snap)
    client.loop_start()
    log.info("mqtt starting ip=%s serial=...%s http=%s:%s", ip, serial[-6:], HOST, PORT)

    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log.info("shutdown")
    finally:
        httpd.server_close()
        client.loop_stop()
        client.disconnect()
    return 0


if __name__ == "__main__":
    sys.exit(main())
