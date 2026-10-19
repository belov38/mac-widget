"""HTTP server exposing the pve snapshot on 127.0.0.1."""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from . import config
from .build import build_snapshot
from .sources import collect as default_collect

PERIODS = ("day", "week", "month")


class SnapshotCache:
    def __init__(self, ttl_s=60, collect=default_collect, clock=time.time):
        self.ttl_s = ttl_s
        self.collect = collect
        self.clock = clock
        self._lock = threading.Lock()
        self._entries = {}  # period -> (stored_at, snapshot)

    def get(self, period):
        with self._lock:
            entry = self._entries.get(period)
            if entry and self.clock() - entry[0] < self.ttl_s:
                return entry[1]
            raw = self.collect(period)
            now = self.clock()
            snap = build_snapshot(period, int(now), raw)
            self._entries[period] = (now, snap)
            return snap


def make_handler(cache, allowed_login):
    class Handler(BaseHTTPRequestHandler):
        timeout = 30  # socket timeout so stalled clients cannot pin a thread
        _t0 = None
        _period = "-"

        def _send(self, status, body, ctype):
            try:
                self.send_response(status)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                took = time.monotonic() - self._t0 if self._t0 is not None else 0.0
                self.log_message("client dropped connection: path=%s period=%s took=%.1fs",
                                 self.path, self._period, took)
                self.close_connection = True

        def _json(self, status, obj):
            self._send(status, json.dumps(obj).encode(), "application/json")

        def log_request(self, code="-", size="-"):
            # Silence the per-request access log; errors still go through log_message.
            pass

        def do_GET(self):
            self._t0 = time.monotonic()
            url = urlparse(self.path)
            if url.path == "/healthz":
                return self._send(200, b"ok", "text/plain")
            if url.path != "/v1/snapshot":
                return self._json(404, {"error": "not found"})
            login = self.headers.get("Tailscale-User-Login")
            if not allowed_login or login != allowed_login:
                self.log_message("forbidden: Tailscale-User-Login=%r", login)
                return self._json(403, {"error": "forbidden"})
            period = parse_qs(url.query).get("period", ["day"])[0]
            if period not in PERIODS:
                return self._json(400, {"error": "invalid period"})
            self._period = period
            try:
                snap = cache.get(period)
            except Exception as e:
                return self._json(502, {"error": f"collection failed: {e}"})
            self._json(200, snap)

    return Handler


def main():
    handler = make_handler(SnapshotCache(), config.ALLOWED_LOGIN)
    ThreadingHTTPServer(("127.0.0.1", config.PORT), handler).serve_forever()


if __name__ == "__main__":
    main()
