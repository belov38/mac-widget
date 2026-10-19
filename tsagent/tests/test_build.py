import unittest
from datetime import datetime, timezone

from tstopo import build

PING_WARMUP = """pong from ws (100.64.0.15) via DERP(syd) in 619ms
pong from ws (100.64.0.15) via 192.168.1.108:41641 in 5ms
"""
PING_DERP = """pong from k3s (100.64.0.19) via DERP(nue) in 1.754s
pong from k3s (100.64.0.19) via DERP(nue) in 590ms
2026/10/19 15:36:07 direct connection not established
"""


def status():
    def peer(pid, dns, uid, online=True, **kw):
        p = dict(ID=pid, DNSName=dns + ".tn.ts.net.", HostName="localhost", UserID=uid, OS="linux",
                 Online=online, TailscaleIPs=["100.64.0." + pid], Relay="syd",
                 LastSeen="0001-01-01T00:00:00Z")
        p.update(kw)
        return p
    return {
        "Self": {"UserID": 1, "DNSName": "mac.tn.ts.net.", "OS": "macOS", "Relay": "syd",
                 "Addrs": ["1.2.3.4:41641", "192.168.1.109:41641"]},
        "Peer": {
            "a": peer("1", "ws", 1),
            "b": peer("2", "k3s", 1),
            "c": peer("3", "old", 1, online=False, LastSeen="2026-10-16T11:10:59.1Z"),
            "d": peer("4", "ct-app", 1),
            "e": peer("5", "foreign", 2),
        },
    }


class ClassifyTests(unittest.TestCase):
    def test_kinds(self):
        self.assertEqual(build.classify("DERP(nue)"), {"kind": "derp", "via": "nue"})
        self.assertEqual(build.classify("192.168.1.116:41641")["kind"], "lan")
        self.assertEqual(build.classify("5.6.7.8:41641")["kind"], "direct")
        self.assertEqual(build.classify("[fe80::1]:41641")["kind"], "lan")
        self.assertEqual(build.classify("[2606:4700::1]:41641")["kind"], "direct")
        self.assertEqual(build.classify("peer-relay(1.2.3.4:7777:vni:3)")["kind"], "peer_relay")

    def test_parse_ping_units(self):
        pongs = build.parse_ping(PING_DERP)
        self.assertEqual([p["ms"] for p in pongs], [1754.0, 590.0])

    def test_path_keeps_first_when_it_differs(self):
        path = build.path_from_pongs(build.parse_ping(PING_WARMUP))
        self.assertEqual(path["kind"], "lan")
        self.assertEqual(path["first"], {"kind": "derp", "via": "syd", "ms": 619.0})
        self.assertNotIn("first", build.path_from_pongs(build.parse_ping(PING_DERP)))

    def test_median_skips_setup_pong(self):
        out = ("pong from h (1) via DERP(syd) in 600ms\n"
               "pong from h (1) via 192.168.1.2:41641 in 90ms\n"
               "pong from h (1) via 192.168.1.2:41641 in 4ms\n"
               "pong from h (1) via 192.168.1.2:41641 in 6ms\n"
               "pong from h (1) via 192.168.1.2:41641 in 5ms\n")
        path = build.path_from_pongs(build.parse_ping(out))
        self.assertEqual((path["ms"], path["minMs"], path["maxMs"], path["n"]), (5.0, 4.0, 6.0, 3))


class BuildTests(unittest.TestCase):
    def test_build(self):
        doc = build.build(status(), {"1": PING_WARMUP, "2": PING_DERP, "4": ""},
                          {"UDP": True, "PreferredDERP": 5, "RegionLatency": {"5": 12_000_000}},
                          {"5": "syd"}, {"ct-app"}, now=datetime(2026, 10, 19, tzinfo=timezone.utc))
        self.assertEqual(doc["generatedAt"], "2026-10-19T00:00:00Z")
        self.assertEqual(doc["self"]["lan"], ["192.168.1.109"])
        self.assertEqual(doc["self"]["preferredDerp"], "syd")
        self.assertEqual(doc["self"]["derpMs"], 12.0)
        by = {n["name"]: n for n in doc["nodes"]}
        self.assertEqual(sorted(by), ["ct-app", "k3s", "old", "ws"])  # foreign node dropped
        self.assertEqual(by["k3s"]["path"]["via"], "nue")
        self.assertEqual(by["ct-app"]["parent"], "pve")
        self.assertEqual(by["ct-app"]["error"], "no pong")
        self.assertIsNone(by["old"]["path"])
        self.assertNotIn("error", by["old"])
        self.assertEqual(by["old"]["lastSeen"], "2026-10-16T11:10:59.1Z")
        self.assertIsNone(by["ws"]["lastSeen"])

    def test_hidden_nodes_dropped(self):
        doc = build.build(status(), {}, None, {}, set(), hidden=frozenset({"old", "k3s"}))
        self.assertEqual(sorted(n["name"] for n in doc["nodes"]), ["ct-app", "ws"])


if __name__ == "__main__":
    unittest.main()
