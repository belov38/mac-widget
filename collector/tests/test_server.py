import contextlib
import http.client
import io
import json
import subprocess
import threading
import time
import unittest
from http.server import ThreadingHTTPServer

from pvewidget.server import SnapshotCache, make_handler
from pvewidget.sources import collect
from tests.test_build import fixture_raw, load

LOGIN = "owner@github"


class FakeClock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t

    def advance(self, s):
        self.t += s


def fake_runner(hang_paths=(), fail_cmd=None):
    def run(argv, timeout):
        if argv[0] == "sensors":
            if fail_cmd == "sensors":
                raise subprocess.CalledProcessError(1, argv)
            return json.dumps(load("sensors.json"))
        assert argv[:2] == ["pvesh", "get"], argv
        path = argv[2]
        if path in hang_paths:
            raise subprocess.TimeoutExpired(argv, timeout)
        if path == "/cluster/resources":
            return json.dumps(load("cluster_resources.json"))
        if path == "/nodes/pve/status":
            return json.dumps(load("node_status.json"))
        if path == "/nodes/pve/rrddata":
            return json.dumps(load("node_rrd_day.json"))
        if path.endswith("/rrddata"):
            return json.dumps(load("qemu102_rrd_day.json"))
        if path == "/nodes/pve/qemu/101/agent/get-fsinfo":
            return json.dumps(load("qemu101_fsinfo.json"))
        if path == "/nodes/pve/qemu/102/agent/get-fsinfo":
            return json.dumps(load("qemu102_fsinfo.json"))
        return json.dumps({"result": []})
    return run


PSI_TEXT = "some avg10=1.00 avg60=2.50 avg300=0.00 total=1\nfull avg10=0.50 avg60=1.25 avg300=0.00 total=1\n"


def fake_reader(paths):
    def read(path):
        paths.append(path)
        if path.startswith("/sys/fs/cgroup/lxc/105"):
            raise FileNotFoundError(path)
        return PSI_TEXT
    return read


class CollectTests(unittest.TestCase):
    def test_raw_shape(self):
        raw = collect("day", runner=fake_runner())
        self.assertEqual(set(raw), {"status", "resources", "sensors", "node_rrd_avg", "node_rrd_max", "psi", "guests"})
        self.assertIn(101, raw["guests"])
        self.assertNotIn(9000, raw["guests"])
        self.assertIsNotNone(raw["guests"][101]["fsinfo"])
        self.assertTrue(raw["guests"][102]["rrd_avg"])

    def test_psi_files(self):
        paths = []
        raw = collect("day", runner=fake_runner(), reader=fake_reader(paths))
        self.assertEqual(raw["psi"], {"cpu": PSI_TEXT, "memory": PSI_TEXT, "io": PSI_TEXT})
        self.assertIn("/proc/pressure/io", paths)
        self.assertEqual(raw["guests"][102]["psi"]["cpu"], PSI_TEXT)
        self.assertIn("/sys/fs/cgroup/qemu.slice/102.scope/memory.pressure", paths)
        self.assertEqual(raw["guests"][105]["psi"], {"cpu": None, "memory": None})
        running = {r["vmid"] for r in load("cluster_resources.json")
                   if r.get("status") == "running" and r.get("template") != 1 and r.get("type") in ("qemu", "lxc")}
        self.assertEqual({v for v, g in raw["guests"].items() if "psi" in g}, running)

    def test_templates_skipped(self):
        res = [r for r in load("cluster_resources.json") if r.get("template") == 1]
        raw = collect("day", runner=fake_runner())
        for r in res:
            self.assertNotIn(r["vmid"], raw["guests"])

    def test_stopped_qemu_has_no_fsinfo_call(self):
        seen = []
        base = fake_runner()

        def run(argv, timeout):
            seen.append(argv)
            out = base(argv, timeout)
            if argv[:3] == ["pvesh", "get", "/cluster/resources"]:
                rows = json.loads(out)
                for r in rows:
                    if r.get("vmid") == 103:
                        r["status"] = "stopped"
                out = json.dumps(rows)
            return out
        raw = collect("day", runner=run)
        self.assertIsNone(raw["guests"][103]["fsinfo"])
        self.assertFalse(any(a[2] == "/nodes/pve/qemu/103/agent/get-fsinfo" for a in seen if a[0] == "pvesh"))

    def test_lxc_has_no_fsinfo_call(self):
        seen = []
        base = fake_runner()

        def run(argv, timeout):
            seen.append(argv)
            return base(argv, timeout)
        collect("week", runner=run)
        self.assertFalse(any("/lxc/" in a[2] and "fsinfo" in a[2] for a in seen if a[0] == "pvesh"))
        rrd = [a for a in seen if a[0] == "pvesh" and a[2] == "/nodes/pve/rrddata"]
        self.assertEqual(sorted(a[-1] for a in rrd), ["AVERAGE", "MAX"])
        self.assertIn("week", rrd[0])

    def test_agent_timeout_gives_null_disk(self):
        raw = collect("day", runner=fake_runner(hang_paths={"/nodes/pve/qemu/101/agent/get-fsinfo"}))
        self.assertIsNone(raw["guests"][101]["fsinfo"])

    def test_sensors_failure_is_none(self):
        self.assertIsNone(collect("day", runner=fake_runner(fail_cmd="sensors"))["sensors"])

    def test_rrd_failure_is_empty(self):
        raw = collect("day", runner=fake_runner(hang_paths={"/nodes/pve/qemu/102/rrddata"}))
        self.assertEqual(raw["guests"][102]["rrd_avg"], [])

    def test_status_failure_raises(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            collect("day", runner=fake_runner(hang_paths={"/nodes/pve/status"}))


class CacheTests(unittest.TestCase):
    def test_cache_ttl(self):
        calls = []
        c = SnapshotCache(60, collect=lambda p: calls.append(p) or fixture_raw(), clock=FakeClock())
        c.get("day")
        c.get("day")
        self.assertEqual(calls, ["day"])
        c.clock.advance(61)
        c.get("day")
        self.assertEqual(calls, ["day", "day"])

    def test_cache_per_period(self):
        calls = []
        c = SnapshotCache(60, collect=lambda p: calls.append(p) or fixture_raw(), clock=FakeClock())
        self.assertEqual(c.get("day")["period"], "day")
        self.assertEqual(c.get("week")["period"], "week")
        self.assertEqual(calls, ["day", "week"])


class BrokenPipeTests(unittest.TestCase):
    def test_broken_pipe_on_write_logs_one_line(self):
        class DeadFile:
            def write(self, b):
                raise BrokenPipeError()

            def flush(self):
                pass

        h = make_handler(None, LOGIN).__new__(make_handler(None, LOGIN))
        h.wfile = DeadFile()
        h.path = "/v1/snapshot?period=week"
        h._period = "week"
        h._t0 = time.monotonic() - 2
        h.request_version = "HTTP/1.1"
        h.requestline = "GET / HTTP/1.1"
        h.command = "GET"
        h.client_address = ("127.0.0.1", 1)
        h._headers_buffer = []
        h.send_response = lambda *a, **k: None
        h.send_header = lambda *a, **k: None
        h.end_headers = lambda: None
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            h._send(200, b"{}", "application/json")
        lines = buf.getvalue().strip().splitlines()
        self.assertEqual(len(lines), 1)
        self.assertIn("period=week", lines[0])
        self.assertIn("path=/v1/snapshot?period=week", lines[0])
        self.assertRegex(lines[0], r"took=\d+\.\ds")

    def test_handler_has_socket_timeout(self):
        self.assertEqual(make_handler(None, LOGIN).timeout, 30)


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.fail_collect = False

        def do_collect(period):
            if self.fail_collect:
                raise RuntimeError("boom")
            return fixture_raw()
        cache = SnapshotCache(60, collect=do_collect, clock=FakeClock())
        handler = make_handler(cache, LOGIN)
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.thread = threading.Thread(target=self.srv.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        self.thread.join()

    def get(self, path, login=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.srv.server_address[1], timeout=10)
        try:
            conn.request("GET", path, headers={"Tailscale-User-Login": login} if login else {})
            r = conn.getresponse()
            body = r.read()
            return r.status, body
        finally:
            conn.close()

    def get_logged(self, path, login=None):
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            status, _ = self.get(path, login)
        return status, buf.getvalue()

    def test_403_logs_received_login(self):
        status, err = self.get_logged("/v1/snapshot", login="someone@else")
        self.assertEqual(status, 403)
        self.assertIn("someone@else", err)

    def test_ok_requests_log_nothing(self):
        self.assertEqual(self.get_logged("/v1/snapshot", login=LOGIN), (200, ""))
        self.assertEqual(self.get_logged("/healthz"), (200, ""))

    def test_auth(self):
        self.assertEqual(self.get_logged("/v1/snapshot")[0], 403)
        self.assertEqual(self.get_logged("/v1/snapshot", login="other.user@")[0], 403)
        status, body = self.get("/v1/snapshot?period=week", login=LOGIN)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["period"], "week")

    def test_default_period(self):
        self.assertEqual(json.loads(self.get("/v1/snapshot", login=LOGIN)[1])["period"], "day")

    def test_bad_period(self):
        self.assertEqual(self.get("/v1/snapshot?period=year", login=LOGIN)[0], 400)

    def test_healthz_no_auth(self):
        self.assertEqual(self.get("/healthz"), (200, b"ok"))

    def test_unknown_path(self):
        self.assertEqual(self.get("/nope", login=LOGIN)[0], 404)

    def test_collect_error_is_502(self):
        self.fail_collect = True
        status, body = self.get("/v1/snapshot", login=LOGIN)
        self.assertEqual(status, 502)
        self.assertIn("error", json.loads(body))


if __name__ == "__main__":
    unittest.main()
