"""Localhost HTTP agent: pings own tailnet nodes and serves the topology JSON.

The widget runs sandboxed and cannot call the tailscale CLI, and a launchd job
cannot write into the App Group container, so the widget fetches from here.
"""
from __future__ import annotations

import json
import logging
import os
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from . import build

TAILSCALE = os.environ.get("TSTOPO_TAILSCALE", "/usr/local/bin/tailscale")
HOST, PORT = "127.0.0.1", int(os.environ.get("TSTOPO_PORT", "9185"))
INTERVAL_S = 600
# A fixed number of pings (no early stop on direct) so the latency is a median, not one sample.
PING_ARGS = ["-c", "8", "--until-direct=false", "--timeout", "2s"]
# TSMP goes through the WireGuard session and wakes peers whose cold disco pings time out.
WAKE_ARGS = ["--tsmp", "-c", "3", "--timeout", "2s"]


def _names(var: str) -> frozenset:
    """Comma-separated node names from an environment variable."""
    return frozenset(n.strip() for n in os.environ.get(var, "").split(",") if n.strip())


# Nodes drawn as guests of the pve host.
PVE_GUESTS = _names("TSTOPO_PVE_GUESTS")
# Nodes that are left out of the topology entirely.
HIDDEN = _names("TSTOPO_HIDDEN")

log = logging.getLogger("tstopo")


def _run(args: list, timeout: float) -> subprocess.CompletedProcess:
    return subprocess.run([TAILSCALE, *args], capture_output=True, text=True, timeout=timeout)


def _json(args: list, timeout: float = 20):
    try:
        r = _run(args, timeout)
        return json.loads(r.stdout) if r.returncode == 0 else None
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError) as e:
        log.warning("tailscale %s failed: %s", args[0], e)
        return None


def _ping(ip: str) -> str | None:
    try:
        # Non-zero exit just means "no direct path"; the pongs are still in stdout.
        out = _run(["ping", *PING_ARGS, ip], timeout=30).stdout
        if not build.parse_ping(out):
            _run(["ping", *WAKE_ARGS, ip], timeout=15)
            out = _run(["ping", *PING_ARGS, ip], timeout=30).stdout
        return out
    except (subprocess.TimeoutExpired, OSError) as e:
        log.warning("ping %s failed: %s", ip, e)
        return None


def collect() -> dict:
    status = _json(["status", "--json"])
    if not status:
        raise RuntimeError("tailscale status failed")
    peers = [p for p in build.own_peers(status, HIDDEN) if p.get("Online") and p.get("TailscaleIPs")]
    with ThreadPoolExecutor(max_workers=24) as pool:
        nc = pool.submit(_json, ["netcheck", "--format=json"], 30)
        dm = pool.submit(_json, ["debug", "derp-map"])
        futures = {p["ID"]: pool.submit(_ping, p["TailscaleIPs"][0]) for p in peers}
        pings = {pid: f.result() for pid, f in futures.items()}
        derp_map = dm.result() or {}
        codes = {k: v.get("RegionCode", k) for k, v in (derp_map.get("Regions") or {}).items()}
        return build.build(status, pings, nc.result(), codes, PVE_GUESTS, hidden=HIDDEN)


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.doc: dict | None = None
        self.at = 0.0  # wall-clock time of the last successful collect

    def refresh(self) -> dict | None:
        # One collect at a time; concurrent callers wait and then reuse a fresh result.
        started = time.time()
        with self.lock:
            if self.doc is not None and self.at >= started:
                return self.doc
            try:
                self.doc, self.at = collect(), time.time()
            except Exception:
                log.exception("collect failed")
            return self.doc

    def get(self, force: bool) -> dict | None:
        if force or self.doc is None or time.time() - self.at >= INTERVAL_S:
            return self.refresh()
        return self.doc


STATE = State()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        if url.path != "/v1/topology":
            self.send_error(404)
            return
        force = parse_qs(url.query).get("refresh") == ["1"]
        doc = STATE.get(force)
        if doc is None:
            self.send_error(503, "no data")
            return
        body = json.dumps(doc).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        log.info("%s %s", self.address_string(), fmt % args)


def loop():
    # Poll the wall clock: monotonic time stops during sleep, so this refreshes soon after wake.
    while True:
        if time.time() - STATE.at >= INTERVAL_S:
            STATE.refresh()
        time.sleep(30)


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    threading.Thread(target=loop, daemon=True).start()
    log.info("listening on %s:%d", HOST, PORT)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
