import json
import os
import unittest

from pvewidget.build import (
    build_host_now, build_snapshot, build_storages, build_temps,
    pick_disk_from_fsinfo, series, stats,
)

FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")


def load(name):
    with open(os.path.join(FIXTURES, name)) as f:
        return json.load(f)


def fixture_raw():
    return {
        "status": load("node_status.json"),
        "resources": load("cluster_resources.json"),
        "sensors": load("sensors.json"),
        "node_rrd_avg": load("node_rrd_day.json"),
        "node_rrd_max": load("node_rrd_day.json"),
        "guests": {
            100: {"rrd_avg": [], "rrd_max": [], "fsinfo": None},
            101: {"rrd_avg": [], "rrd_max": [], "fsinfo": load("qemu101_fsinfo.json")},
            102: {"rrd_avg": load("qemu102_rrd_day.json"), "rrd_max": load("qemu102_rrd_day.json"),
                  "fsinfo": load("qemu102_fsinfo.json")},
            103: {"rrd_avg": [], "rrd_max": [], "fsinfo": None},
        },
    }


class BuildTests(unittest.TestCase):
    def test_temps_from_fixture(self):
        t = {x["id"]: x for x in build_temps(load("sensors.json"))}
        self.assertEqual(list(t), ["cpu", "nvme970", "nvmep310", "dimm_a0", "dimm_a1", "dimm_b0", "dimm_b1", "e810", "rtl8127"])
        self.assertEqual((t["cpu"]["value"], t["cpu"]["warn"], t["cpu"]["crit"]), (79.0, 85.0, 95.0))
        self.assertEqual((t["dimm_a1"]["value"], t["dimm_a1"]["warn"], t["dimm_a1"]["crit"]), (56.5, 55.0, 85.0))
        self.assertAlmostEqual(t["nvme970"]["warn"], 74.85)  # max == crit 84.85 -> crit - 10
        self.assertEqual((t["rtl8127"]["warn"], t["rtl8127"]["crit"]), (100.0, 110.0))

    def test_unknown_and_missing_sensors(self):
        self.assertEqual(build_temps(None), [])
        self.assertEqual(build_temps({"acpitz-acpi-0": {"temp1": {"temp1_input": 27.8}}}), [])
        only_cpu = {"coretemp-isa-0000": load("sensors.json")["coretemp-isa-0000"]}
        self.assertEqual([x["id"] for x in build_temps(only_cpu)], ["cpu"])

    def test_storages(self):
        s = build_storages(load("cluster_resources.json"))
        self.assertEqual([x["label"] for x in s], ["vmdata", "local-lvm", "root"])
        self.assertEqual(s[0]["used"], 874719466854)
        self.assertEqual(s[0]["total"], 1696507887616)

    def test_host_now(self):
        h = build_host_now(load("node_status.json"), load("cluster_resources.json"))
        self.assertEqual(h["name"], "pve")
        self.assertEqual(h["cpus"], 24)
        self.assertEqual(len(h["load"]), 3)
        self.assertEqual(h["load"][0], 17.77)
        self.assertGreater(h["mem_total"], 0)
        self.assertAlmostEqual(h["cpu_now"], 0.922589869281046)
        self.assertEqual(h["uptime_s"], 255291)
        self.assertEqual(h["swap_total"], 34359734272)

    def test_storages_skip_incomplete(self):
        res = [{"type": "storage", "storage": "vmdata"},
               {"type": "storage", "storage": "local", "disk": 1, "maxdisk": 2}]
        self.assertEqual([x["id"] for x in build_storages(res)], ["local"])

    def test_series_downsample(self):
        s = series(load("node_rrd_day.json"), "cpu")
        self.assertLessEqual(len(s), 96)
        self.assertTrue(all(0 <= avg <= 1 for _, avg, _ in s))
        self.assertLess(s[0][0], s[-1][0])

    def test_series_points_have_avg_and_max(self):
        rows = load("node_rrd_day.json")
        s = series(rows, "cpu", max_rows=rows)
        self.assertTrue(all(len(p) == 3 for p in s))
        self.assertTrue(all(mx >= avg for _, avg, mx in s))

    def test_series_max_matches_peak(self):
        rows = load("node_rrd_day.json")
        s = series(rows, "cpu", max_rows=rows)
        self.assertEqual(max(mx for _, _, mx in s), stats(rows, rows, "cpu")[1])
        self.assertLess(max(avg for _, avg, _ in s), max(mx for _, _, mx in s))

    def test_series_max_by_bucket_time(self):
        avg_rows = [{"time": t, "cpu": 0.1} for t in range(1, 9)]
        max_rows = [{"time": 2, "cpu": 0.9}, {"time": 3, "cpu": 0.4}, {"time": 6, "cpu": 0.7}]
        # Buckets: (..2], (2..4], (4..6], (6..8]; the last one has no MAX rows.
        self.assertEqual(series(avg_rows, "cpu", max_points=4, max_rows=max_rows),
                         [[2, 0.1, 0.9], [4, 0.1, 0.4], [6, 0.1, 0.7], [8, 0.1, 0.1]])

    def test_series_without_max_rows_falls_back_to_avg(self):
        rows = [{"time": 1, "cpu": 0.2}, {"time": 2, "cpu": 0.4}]
        self.assertEqual(series(rows, "cpu"), [[1, 0.2, 0.2], [2, 0.4, 0.4]])
        self.assertEqual(series(rows, "cpu", max_rows=[{"time": 2}]), [[1, 0.2, 0.2], [2, 0.4, 0.4]])

    def test_series_max_never_below_avg(self):
        rows = [{"time": 1, "cpu": 0.5}]
        self.assertEqual(series(rows, "cpu", max_rows=[{"time": 1, "cpu": 0.3}]), [[1, 0.5, 0.5]])

    def test_rrd_gaps(self):
        rows = [{"time": 1}, {"time": 2, "cpu": 0.5}, {"time": 3, "mem": 1, "maxmem": 0}]
        self.assertEqual(series(rows, "cpu"), [[2, 0.5, 0.5]])
        self.assertEqual(series(rows, "mem", denom_key="maxmem"), [])
        max_rows = [{"time": 2, "mem": 4, "maxmem": 0}, {"time": 2, "cpu": 0.8}]
        self.assertEqual(series(rows, "cpu", max_rows=max_rows), [[2, 0.5, 0.8]])
        self.assertEqual(stats([{"time": 1}], [{"time": 1}], "cpu"), (None, None))

    def test_disk_from_fsinfo(self):
        self.assertEqual(pick_disk_from_fsinfo(load("qemu101_fsinfo.json"))["mount"], "C:\\")
        self.assertEqual(pick_disk_from_fsinfo(load("qemu102_fsinfo.json"))["mount"], "/")
        self.assertIsNone(pick_disk_from_fsinfo({"result": {"error": {"class": "x"}}}))

    def test_snapshot_from_fixtures(self):
        snap = build_snapshot("day", 1792366260, fixture_raw())
        self.assertEqual(snap["schema"], 1)
        self.assertEqual(snap["period"], "day")
        self.assertEqual([g["vmid"] for g in snap["guests"]], [100, 101, 102, 103, 104, 105])
        g105 = snap["guests"][-1]
        self.assertEqual(g105["disk"]["used"], 2135760896)
        self.assertIsNone(snap["guests"][0]["disk"])
        h = snap["host"]
        self.assertEqual(h["name"], "pve")
        self.assertLessEqual(len(h["cpu"]["series"]), 96)
        self.assertIsNotNone(h["mem"]["avg"])
        self.assertEqual(h["storages"][0]["id"], "vmdata")
        self.assertEqual(snap["guests"][0]["cpu"]["series"], [])
        self.assertIsNone(snap["guests"][0]["cpu"]["avg"])
        self.assertGreater(len(snap["guests"][2]["cpu"]["series"]), 0)
        for m in (h["cpu"], h["mem"], snap["guests"][2]["cpu"]):
            self.assertTrue(all(len(p) == 3 and p[2] >= p[1] for p in m["series"]))
            self.assertEqual(max(p[2] for p in m["series"]), m["peak"])

    def test_null_guest_fields_never_emitted(self):
        raw = fixture_raw()
        for r in raw["resources"]:
            if r.get("vmid") == 102:
                r.update({"maxcpu": None, "name": None, "mem": None, "maxmem": None, "cpu": None})
        g = [x for x in build_snapshot("day", 1, raw)["guests"] if x["vmid"] == 102][0]
        self.assertEqual(g["cpus"], 0)
        self.assertEqual(g["name"], f"{g['type']} 102")
        self.assertEqual(g["mem"], {"used": 0, "total": 0})
        self.assertEqual(g["cpu"]["now"], 0.0)


if __name__ == "__main__":
    unittest.main()
