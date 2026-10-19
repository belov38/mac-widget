# pve Desktop Widgets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two macOS Extra Large desktop widgets ("Host", "Guests") showing load, temperatures and free disk of Proxmox host `pve` and its guests, with a linked 24h / 1w / 1m period switch.

**Architecture:** A stdlib-only Python collector on pve gathers `pvesh`, `sensors -j` and guest-agent data, caches it, and serves one JSON snapshot on `127.0.0.1:9184`, exposed tailnet-only through `tailscale serve` (HTTPS 9443) and gated on the `Tailscale-User-Login` header. A SwiftUI/WidgetKit app on the Mac fetches the snapshot on timeline refresh; period choice lives in an App Group shared by both widgets.

**Tech Stack:** Python 3.13 stdlib (`http.server`, `subprocess`, `concurrent.futures`, `unittest`), systemd, Tailscale Serve; Swift 6, SwiftUI, WidgetKit, Swift Charts, AppIntents, XcodeGen, Xcode 27, macOS 26.

**Spec:** `docs/superpowers/specs/2026-10-19-pve-widget-design.md`

## Global Constraints

- Code comments in English only.
- No commit trailers for AI/Claude, no session links in commits.
- Collector: Python stdlib only (pve has no pip packages; tests use `unittest`, runnable on the Mac with `python3 -m unittest`).
- Collector listens on `127.0.0.1:9184` only; public entry is `https://pve.example.ts.net:9443/v1/snapshot?period=day|week|month`.
- Allowed login: the owner's Tailscale login (`PVEWIDGET_ALLOWED_LOGIN`, e.g. `user@github`). Any other or missing `Tailscale-User-Login` → HTTP 403.
- Hide templates (`template == 1`). Stopped guests appear with status `stopped`.
- Periods: UI labels `24h`, `1w`, `1m` ↔ API values `day`, `week`, `month`. Default `day`.
- Thresholds (warn / crit): CPU load 0.70 / 0.90; RAM 0.80 / 0.95; disk used 0.80 / 0.90; CPU temp 85 / 95 °C; other sensors use their own `sensors -j` limits (DIMM 55 / 85, E810 95 / 105, NVMe max / crit).
- Widgets: both `systemExtraLarge`, native macOS 26 glass background (`containerBackground(.fill.tertiary, for: .widget)` or system default), must render in desaturated (accented) mode.
- Refresh: timeline policy `.after(now + 5 min)`.
- Signing: automatic, team from `app/Config.xcconfig`. Bundle ids `<prefix>.pvewidget`, `<prefix>.pvewidget.widgets`. App Group `<team>.<prefix>.pvewidget`.
- Tap targets: Host → `https://pve.example.ts.net:8006/#v1:0:=node%2Fpve`; guest → `https://pve.example.ts.net:8006/#v1:0:=<type>%2F<vmid>` (via custom scheme `pvewidget://open?target=<type>/<vmid>` handled by the app, which opens the browser).
- On pve confirm before risky changes and back up files before editing them.

## Review Focus

1. Guest agent hangs or VM is stopped → collector still answers within ~10 s, that guest has `disk: null`, card shows "—" for disk. (Task 3 test `test_agent_timeout_gives_null_disk`.)
2. pve unreachable or 403 → widget shows the last cached snapshot with "data from HH:MM"; with no cache at all it shows a readable "No data from pve" state, never a crash or blank. (Task 6 test `test_provider_falls_back_to_cache`, `test_provider_no_cache_gives_error_entry`.)
3. A new guest appears, or there are 7–8 guests → Guests grid fits 8; more than 8 shows the first 8 by VMID plus a "+N" chip. (Task 7 test `test_guest_grid_overflow`.)
4. `sensors` fails, a chip is missing or unknown → temps list just omits it; the snapshot is still valid. (Task 1 test `test_unknown_and_missing_sensors`.)
5. RRD rows with missing keys (new guest, gaps) → series skips those points; avg/peak are computed from the remaining ones, `null` when none. (Task 2 test `test_rrd_gaps`.)

---

## File Structure

```
mac-widget/
  .gitignore                       # .superpowers/, app/build/, *.xcodeproj (generated), __pycache__/
  collector/
    pvewidget/__init__.py
    pvewidget/config.py            # constants: port, allowed login, sensor label map, thresholds
    pvewidget/build.py             # pure: raw dicts -> snapshot dict (host, temps, storages, guests, series)
    pvewidget/sources.py           # runs pvesh / sensors with timeouts, parallel fetch -> raw dicts
    pvewidget/server.py            # HTTP handler, auth, per-period cache, main()
    tests/fixtures/*.json          # real pve data captured 2026-10-19 (already present)
    tests/test_build.py
    tests/test_server.py
    deploy/pvewidget.service
    deploy/deploy.sh               # rsync to pve:/opt/pvewidget, install unit, restart, set serve
  app/
    project.yml                    # XcodeGen spec
    Shared/Snapshot.swift          # Codable model of the JSON
    Shared/Period.swift
    Shared/Thresholds.swift
    Shared/Format.swift
    Shared/AppGroup.swift          # PeriodStore + SnapshotCache (App Group container)
    Shared/SnapshotClient.swift
    Widgets/PveWidgetBundle.swift
    Widgets/SnapshotProvider.swift
    Widgets/SetPeriodIntent.swift
    Widgets/PeriodSwitch.swift
    Widgets/ThresholdLineChart.swift
    Widgets/HostWidgetView.swift
    Widgets/GuestsWidgetView.swift
    Widgets/Widgets.entitlements
    App/PveWidgetApp.swift         # preview window + pvewidget:// URL handler
    App/App.entitlements
    Tests/Fixtures/snapshot.json   # golden output of the collector (Task 2)
    Tests/SharedTests.swift
    Tests/ProviderTests.swift
    Tests/LayoutTests.swift
```

## Snapshot JSON (contract between collector and app)

```json
{
  "schema": 1,
  "generated_at": 1792366260,
  "period": "day",
  "host": {
    "name": "pve", "uptime_s": 253000, "cpus": 24, "load": [10.7, 9.2, 7.2],
    "cpu": {"now": 0.44, "avg": 0.31, "peak": 0.92, "series": [[1792280000, 0.12], "..."]},
    "mem": {"used": 107580522496, "total": 134464360448, "avg": 0.78, "peak": 0.82, "series": [[t, 0.79], "..."]},
    "swap": {"used": 1012924416, "total": 34359734272},
    "temps": [{"id": "cpu", "label": "CPU", "value": 79.0, "warn": 85.0, "crit": 95.0}],
    "storages": [{"id": "vmdata", "label": "vmdata", "used": 874719466854, "total": 1696507887616}]
  },
  "guests": [
    {"vmid": 102, "type": "qemu", "name": "vm-tools", "status": "running", "cpus": 22,
     "cpu": {"now": 0.94, "avg": 0.38, "peak": 0.97, "series": [[t, 0.5], "..."]},
     "mem": {"used": 45327728640, "total": 60129542144},
     "disk": {"used": 582720000000, "total": 832000000000, "mount": "/"}}
  ]
}
```

All ratios are 0…1. `series` has at most 96 points, oldest first. `avg`, `peak`, `disk` may be `null`. Guests sorted by `vmid`.

---

### Task 1: Collector build — host, temperatures, storages

**Files:**
- Create: `collector/pvewidget/__init__.py`, `collector/pvewidget/config.py`, `collector/pvewidget/build.py`
- Test: `collector/tests/test_build.py`

**Interfaces:**
- Produces in `build.py`:
  - `build_temps(sensors: dict | None) -> list[dict]` — items `{id, label, value, warn, crit}`.
  - `build_storages(resources: list[dict]) -> list[dict]` — items `{id, label, used, total}`.
  - `build_host_now(status: dict, resources: list[dict]) -> dict` — keys `name, uptime_s, cpus, load, cpu_now, mem_used, mem_total, swap_used, swap_total`.
- Produces in `config.py`: `SENSOR_LABELS: dict[str, tuple[str, str]]` (chip → (id, label)), `CPU_TEMP = (85.0, 95.0)`, `STORAGES = [("vmdata","vmdata"), ("local-lvm","local-lvm"), ("local","root")]`, `ALLOWED_LOGIN` (from `PVEWIDGET_ALLOWED_LOGIN`), `PORT = 9184`.

Sensor map (chip → id, label), value field is the first `*_input` of the listed feature:
`coretemp-isa-0000`/`Package id 0` → `cpu`,`CPU`; `nvme-pci-ae00`/`Composite` → `nvme970`,`NVMe 970`; `nvme-pci-8100`/`Composite` → `nvmep310`,`NVMe P310`; `spd5118-i2c-0-50..53`/`temp1` → `dimm_a0`,`DIMM A0` / `dimm_a1` / `dimm_b0` / `dimm_b1`; `ice-pci-0100`/`temp1` → `e810`,`E810`; `r8169_0_ab00:00-mdio-0`/`temp1` → `rtl8127`,`RTL8127`. Others (e.g. `acpitz`) are skipped.

Limits rule: CPU uses `CPU_TEMP`. Others: `warn = *_max`, `crit = *_crit` or `*_max` if absent; if `warn >= crit` then `warn = crit - 10`.

- [ ] **Step 1: Init repo.** `git init` in `mac-widget/`, add `.gitignore` (see File Structure), commit the spec and fixtures.

- [ ] **Step 2: Write failing tests** in `test_build.py` using `tests/fixtures/sensors.json`, `cluster_resources.json`, `node_status.json`:

```python
def test_temps_from_fixture(self):
    t = {x["id"]: x for x in build_temps(load("sensors.json"))}
    self.assertEqual(list(t), ["cpu","nvme970","nvmep310","dimm_a0","dimm_a1","dimm_b0","dimm_b1","e810","rtl8127"])
    self.assertEqual((t["cpu"]["value"], t["cpu"]["warn"], t["cpu"]["crit"]), (79.0, 85.0, 95.0))
    self.assertEqual((t["dimm_a1"]["value"], t["dimm_a1"]["warn"], t["dimm_a1"]["crit"]), (56.5, 55.0, 85.0))
    self.assertAlmostEqual(t["nvme970"]["warn"], 74.85)   # max == crit 84.85 -> crit - 10
    self.assertEqual((t["rtl8127"]["warn"], t["rtl8127"]["crit"]), (100.0, 110.0))

def test_unknown_and_missing_sensors(self):
    self.assertEqual(build_temps(None), [])
    self.assertEqual(build_temps({"acpitz-acpi-0": {"temp1": {"temp1_input": 27.8}}}), [])
    only_cpu = {"coretemp-isa-0000": load("sensors.json")["coretemp-isa-0000"]}
    self.assertEqual([x["id"] for x in build_temps(only_cpu)], ["cpu"])

def test_storages(self):
    s = build_storages(load("cluster_resources.json"))
    self.assertEqual([x["label"] for x in s], ["vmdata", "local-lvm", "root"])
    self.assertEqual(s[0]["used"], 874719466854); self.assertEqual(s[0]["total"], 1696507887616)

def test_host_now(self):
    h = build_host_now(load("node_status.json"), load("cluster_resources.json"))
    self.assertEqual(h["name"], "pve"); self.assertEqual(h["cpus"], 24)
    self.assertEqual(len(h["load"]), 3); self.assertGreater(h["mem_total"], 0)
```

Sort order of temps = order of `SENSOR_LABELS`. `load` values are floats parsed from `node_status["loadavg"]` (strings).

- [ ] **Step 3: Run** `cd collector && python3 -m unittest tests.test_build -v` → FAIL (import error).
- [ ] **Step 4: Implement** `config.py` and the three functions in `build.py`.
- [ ] **Step 5: Run** the same command → all PASS.
- [ ] **Step 6: Commit** `feat(collector): host, temps and storages builder`.

---

### Task 2: Collector build — series, guests, full snapshot, golden file

**Files:**
- Modify: `collector/pvewidget/build.py`
- Test: `collector/tests/test_build.py`
- Create: `app/Tests/Fixtures/snapshot.json` (generated)

**Interfaces:**
- Consumes: Task 1 functions.
- Produces in `build.py`:
  - `series(rows: list[dict], key: str, max_points: int = 96, denom_key: str | None = None) -> list[list[float]]` — `[[time, value]]`, value = `row[key] / row[denom_key]` when `denom_key`; rows lacking `key`, `time` or with `denom == 0` are skipped; downsampled by averaging into `max_points` equal buckets.
  - `stats(avg_rows, max_rows, key, denom_key=None) -> tuple[float | None, float | None]` — (mean over AVERAGE rows, max over MAX rows), `None` when no valid rows.
  - `build_guest(res: dict, rrd_avg: list, rrd_max: list, disk: dict | None) -> dict` — one guest object per contract.
  - `pick_disk_from_fsinfo(fsinfo: dict) -> dict | None` — filesystem with the largest `total-bytes`; returns `{used, total, mount}`; `None` on error result.
  - `build_snapshot(period: str, now: int, raw: dict) -> dict` — `raw` keys: `status, resources, sensors, node_rrd_avg, node_rrd_max, guests: {vmid: {"rrd_avg", "rrd_max", "fsinfo"}}`.
- Guest disk: `lxc` → `res["disk"] / res["maxdisk"]`, mount `/`; `qemu` running → `pick_disk_from_fsinfo`; stopped → `None`. Guest `cpus` = `res["maxcpu"]`. `mem` = `res["mem"] / res["maxmem"]` (Windows 101 reported as-is; no special handling). Node mem ratio = `memused/memtotal`.

- [ ] **Step 1: Write failing tests:**

```python
def test_series_downsample(self):
    s = series(load("node_rrd_day.json"), "cpu")
    self.assertLessEqual(len(s), 96); self.assertTrue(all(0 <= v <= 1 for _, v in s))
    self.assertLess(s[0][0], s[-1][0])

def test_rrd_gaps(self):
    rows = [{"time": 1}, {"time": 2, "cpu": 0.5}, {"time": 3, "mem": 1, "maxmem": 0}]
    self.assertEqual(series(rows, "cpu"), [[2, 0.5]])
    self.assertEqual(series(rows, "mem", denom_key="maxmem"), [])
    self.assertEqual(stats([{"time": 1}], [{"time": 1}], "cpu"), (None, None))

def test_disk_from_fsinfo(self):
    self.assertEqual(pick_disk_from_fsinfo(load("qemu101_fsinfo.json"))["mount"], "C:\\")
    self.assertEqual(pick_disk_from_fsinfo(load("qemu102_fsinfo.json"))["mount"], "/")
    self.assertIsNone(pick_disk_from_fsinfo({"result": {"error": {"class": "x"}}}))

def test_snapshot_from_fixtures(self):
    snap = build_snapshot("day", 1792366260, fixture_raw())   # helper in the test file
    self.assertEqual(snap["schema"], 1)
    self.assertEqual([g["vmid"] for g in snap["guests"]], [100, 101, 102, 103, 104, 105])
    g105 = snap["guests"][-1]; self.assertEqual(g105["disk"]["used"], 2135760896)
    self.assertIsNone(snap["guests"][0]["disk"])   # 100 has no fsinfo in fixture_raw -> None
```

`fixture_raw()` uses `qemu102_rrd_day.json` for guest 102 and empty lists for the others, `qemu101_fsinfo.json`/`qemu102_fsinfo.json` for 101/102, `None` fsinfo for 100 and 103.

- [ ] **Step 2: Run** `python3 -m unittest tests.test_build -v` → new tests FAIL.
- [ ] **Step 3: Implement** the functions.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Generate golden file:** `python3 -c "import json,tests.test_build as t; from pvewidget.build import build_snapshot; print(json.dumps(build_snapshot('day',1792366260,t.fixture_raw()),indent=1))" > ../app/Tests/Fixtures/snapshot.json`; check it parses with `python3 -m json.tool`.
- [ ] **Step 6: Commit** `feat(collector): guests, series and snapshot builder`.

---

### Task 3: Collector sources and HTTP server

**Files:**
- Create: `collector/pvewidget/sources.py`, `collector/pvewidget/server.py`
- Test: `collector/tests/test_server.py`

**Interfaces:**
- Consumes: `build_snapshot`, `config`.
- Produces:
  - `sources.Runner = Callable[[list[str], float], str]` (argv, timeout → stdout; raises on failure/timeout). Default `run_cmd` uses `subprocess.run(..., timeout=)`.
  - `sources.collect(period: str, runner: Runner = run_cmd) -> dict` — returns the `raw` dict of Task 2. Runs all `pvesh get ... --output-format json` calls in a `ThreadPoolExecutor(max_workers=8)`. RRD: `/nodes/pve/rrddata` and `/nodes/pve/{type}/{vmid}/rrddata` with `--timeframe {period} --cf AVERAGE` and `--cf MAX`. fsinfo: `/nodes/pve/qemu/{vmid}/agent/get-fsinfo` only for running qemu guests, timeout 5 s, failure → `None`. `sensors -j` failure → `None` (stderr ignored). Other call timeouts 10 s; a failure of `status` or `resources` raises.
  - `server.SnapshotCache(ttl_s=60, collect=..., clock=time.time)` with `get(period) -> dict` (cached per period, single collection at a time via a lock).
  - `server.make_handler(cache, allowed_login) -> type[BaseHTTPRequestHandler]`; routes: `GET /v1/snapshot?period=` (default `day`, invalid → 400), `GET /healthz` → 200 `ok` (no auth). Auth: header `Tailscale-User-Login` must equal `allowed_login`, else 403. Collection error → 502 with `{"error": "..."}`.
  - `server.main()` binds `127.0.0.1:PORT` with `ThreadingHTTPServer`.

- [ ] **Step 1: Write failing tests** with a fake runner that serves fixture files by argv path and a real `ThreadingHTTPServer` on port 0:

```python
def test_agent_timeout_gives_null_disk(self):
    raw = collect("day", runner=fake_runner(hang_paths={"/nodes/pve/qemu/101/agent/get-fsinfo"}))
    self.assertIsNone(raw["guests"][101]["fsinfo"])

def test_sensors_failure_is_none(self):
    self.assertIsNone(collect("day", runner=fake_runner(fail_cmd="sensors"))["sensors"])

def test_auth(self):
    self.assertEqual(get("/v1/snapshot", login=None).status, 403)
    self.assertEqual(get("/v1/snapshot", login="other.user@").status, 403)
    r = get("/v1/snapshot?period=week", login="owner@github")
    self.assertEqual(r.status, 200); self.assertEqual(r.json()["period"], "week")

def test_bad_period(self):
    self.assertEqual(get("/v1/snapshot?period=year", login="owner@github").status, 400)

def test_cache_ttl(self):
    calls = []; c = SnapshotCache(60, collect=lambda p: calls.append(p) or fixture_raw(), clock=FakeClock())
    c.get("day"); c.get("day"); self.assertEqual(calls, ["day"])
    c.clock.advance(61); c.get("day"); self.assertEqual(calls, ["day", "day"])
```

`fake_runner(hang_paths)` raises `subprocess.TimeoutExpired` for those paths (no real sleeping).

- [ ] **Step 2: Run** `python3 -m unittest tests.test_server -v` → FAIL.
- [ ] **Step 3: Implement** `sources.py` and `server.py` (`python3 -m pvewidget.server` runs `main()`).
- [ ] **Step 4: Run** `python3 -m unittest discover -s tests -v` → all PASS.
- [ ] **Step 5: Smoke on pve:** `rsync -a collector/ pve:/tmp/pvewidget/ && ssh pve 'cd /tmp/pvewidget && python3 -c "import time,json;from pvewidget.sources import collect;from pvewidget.build import build_snapshot;t=time.time();s=build_snapshot(\"week\",int(t),collect(\"week\"));print(round(time.time()-t,1),len(s[\"guests\"]),[x[\"id\"] for x in s[\"host\"][\"temps\"]])"'` → finishes in under 10 s, 6 guests, 9 temp ids.
- [ ] **Step 6: Commit** `feat(collector): sources, cache and HTTP server`.

---

### Task 4: Deploy collector on pve and expose via Tailscale Serve

**Files:**
- Create: `collector/deploy/pvewidget.service`, `collector/deploy/deploy.sh`

**Interfaces:**
- Produces: `https://pve.example.ts.net:9443/v1/snapshot?period=day|week|month` for Task 6.

Unit: `User=root`, `WorkingDirectory=/opt/pvewidget`, `ExecStart=/usr/bin/python3 -m pvewidget.server`, `Restart=on-failure`, `NoNewPrivileges=yes`. `deploy.sh`: rsync `collector/pvewidget` to `pve:/opt/pvewidget/`, install unit to `/etc/systemd/system/`, `systemctl daemon-reload && systemctl enable --now pvewidget && systemctl restart pvewidget`, then `tailscale serve --bg --https=9443 http://127.0.0.1:9184` (idempotent).

- [ ] **Step 1: Write unit and script.**
- [ ] **Step 2: Run** `collector/deploy/deploy.sh`.
- [ ] **Step 3: Verify on pve:** `ssh pve 'systemctl is-active pvewidget; curl -s 127.0.0.1:9184/healthz; ss -ltnp | grep 9184; tailscale serve status'` → `active`, `ok`, bound to `127.0.0.1:9184` only, serve route `https://pve.example.ts.net:9443 → http://127.0.0.1:9184`.
- [ ] **Step 4: Verify from Mac:** `curl -s -o /dev/null -w '%{http_code}\n' https://pve.example.ts.net:9443/v1/snapshot?period=day` → `200` (Serve adds the login header for the owner), and the body has 6 guests. If it is 403, print the received header in the handler log and fix `ALLOWED_LOGIN` to the actual value.
- [ ] **Step 5: Verify from LAN that 9184 is closed:** `nc -z -G 3 192.168.1.116 9184; echo $?` → non-zero.
- [ ] **Step 6: Commit** `feat(collector): systemd unit and deploy script`.

---

### Task 5: Xcode project and shared model

**Files:**
- Create: `app/project.yml`, `app/Shared/Snapshot.swift`, `Period.swift`, `Thresholds.swift`, `Format.swift`, `app/App/PveWidgetApp.swift` (minimal stub), entitlements, `app/Tests/SharedTests.swift`

**Interfaces:**
- Consumes: `app/Tests/Fixtures/snapshot.json` (Task 2).
- Produces:
  - `struct Snapshot: Codable, Sendable` mirroring the contract (`generatedAt: Date` from epoch seconds, `host: Host`, `guests: [Guest]`); `Metric { now: Double; avg: Double?; peak: Double?; series: [Point] }`, `Point { t: Date; v: Double }` decoded from `[t, v]`; `Guest { vmid: Int; type: String; name: String; status: String; cpus: Int; cpu: Metric; mem: Usage; disk: Disk? }`; `Usage { used: Int64; total: Int64; ratio: Double }`; `Temp { id, label: String; value, warn, crit: Double }`; `Storage { id, label: String; used, total: Int64 }`. `JSONDecoder` with `.convertFromSnakeCase`, helper `Snapshot.decode(_ data: Data) throws -> Snapshot`.
  - `enum Period: String, CaseIterable, AppEnum { case day, week, month }`, `var label` = `"24h"`, `"1w"`, `"1m"`.
  - `enum Level { case ok, warn, crit }`; `struct Threshold { let warn: Double; let crit: Double; func level(_ v: Double) -> Level }`; `extension Threshold { static let cpu = Threshold(warn: 0.70, crit: 0.90); static let mem = (0.80, 0.95); static let disk = (0.80, 0.90) }`; `Temp.level`.
  - `enum Format { static func bytes(_ b: Int64) -> String; static func percent(_ r: Double) -> String; static func usage(_ used: Int64, _ total: Int64) -> String; static func free(_ used: Int64, _ total: Int64) -> String }`.

project.yml: targets `PveWidget` (application, macOS 26.0, sources `App`, `Shared`), `PveWidgetWidgets` (app-extension, `com.apple.widgetkit-extension`, sources `Widgets`, `Shared`, embedded in the app), `PveWidgetTests` (bundle.unit-test, host `PveWidget`, sources `Tests`, `Shared`, `Widgets` excluding `PveWidgetBundle.swift`; resources `Tests/Fixtures`). Entitlements: app sandbox, `com.apple.security.network.client`, App Group. App registers URL scheme `pvewidget`.

- [ ] **Step 1:** `brew install xcodegen`; write `project.yml` and stubs; `cd app && xcodegen generate` → `PveWidget.xcodeproj` created.
- [ ] **Step 2: Write failing tests** in `SharedTests.swift`:

```swift
func testDecodeGoldenSnapshot() throws {
    let s = try Snapshot.decode(fixture("snapshot.json"))
    XCTAssertEqual(s.guests.map(\.vmid), [100, 101, 102, 103, 104, 105])
    XCTAssertEqual(s.host.temps.first?.label, "CPU")
    XCTAssertNil(s.guests[0].disk)
    XCTAssertLessThanOrEqual(s.host.cpu.series.count, 96)
}
func testThresholds() {
    XCTAssertEqual(Threshold.cpu.level(0.69), .ok); XCTAssertEqual(Threshold.cpu.level(0.70), .warn)
    XCTAssertEqual(Threshold.cpu.level(0.90), .crit)
    XCTAssertEqual(Temp(id: "dimm_a1", label: "DIMM A1", value: 56.5, warn: 55, crit: 85).level, .warn)
}
func testFormat() {
    XCTAssertEqual(Format.usage(45_327_728_640, 60_129_542_144), "42/56G")   // GiB, no decimals >= 10
    XCTAssertEqual(Format.usage(244_899_840, 2_147_483_648), "0.2/2G")
    XCTAssertEqual(Format.free(582_720_000_000, 832_000_000_000), "232G free")
    XCTAssertEqual(Format.percent(0.441), "44%")
    XCTAssertEqual(Period.allCases.map(\.label), ["24h", "1w", "1m"])
}
```

- [ ] **Step 3: Run** `xcodebuild test -project app/PveWidget.xcodeproj -scheme PveWidget -destination 'platform=macOS' -only-testing:PveWidgetTests/SharedTests` → FAIL.
- [ ] **Step 4: Implement** the Shared files.
- [ ] **Step 5: Run** the same → PASS.
- [ ] **Step 6: Commit** `feat(app): project and shared snapshot model`.

---

### Task 6: Data flow — client, App Group store, provider, period intent

**Files:**
- Create: `app/Shared/SnapshotClient.swift`, `app/Shared/AppGroup.swift`, `app/Widgets/SnapshotProvider.swift`, `app/Widgets/SetPeriodIntent.swift`
- Test: `app/Tests/ProviderTests.swift`

**Interfaces:**
- Consumes: `Snapshot`, `Period`.
- Produces:
  - `protocol SnapshotFetching: Sendable { func fetch(_ p: Period) async throws -> Snapshot }`; `struct SnapshotClient: SnapshotFetching` with `baseURL = URL(string: "https://pve.example.ts.net:9443")!`, timeout 15 s, non-200 → throws.
  - `enum PeriodStore { static func get(_ d: UserDefaults = .group) -> Period; static func set(_ p: Period, _ d: UserDefaults = .group) }`, `UserDefaults.group` = suite `AppGroup.id`.
  - `struct SnapshotCache { init(dir: URL); func save(_ data: Data, for: Period); func load(_ p: Period) -> Snapshot?; func loadAny() -> Snapshot? }` (raw JSON files in the group container; `loadAny` = newest file).
  - `struct PveEntry: TimelineEntry { date: Date; period: Period; snapshot: Snapshot?; stale: Bool; error: String? }`.
  - `func makeEntry(period: Period, fetcher: SnapshotFetching, cache: SnapshotCache, now: Date) async -> PveEntry` — fetch → save → fresh entry; on error → cache for period, else `loadAny()`, `stale: true`; nothing cached → `snapshot: nil, error: "No data from pve"`.
  - `struct SnapshotProvider: TimelineProvider` using `makeEntry`, policy `.after(now + 300)`; placeholder uses the golden-like sample built in code.
  - `struct SetPeriodIntent: AppIntent { @Parameter var period: Period; perform() → PeriodStore.set, WidgetCenter.shared.reloadAllTimelines() }`.

- [ ] **Step 1: Write failing tests** (fake fetcher, temp dir cache, in-memory `UserDefaults(suiteName: UUID().uuidString)`):

```swift
func testProviderFreshFetchSavesCache() async { /* ok fetch -> stale false, cache.load(.day) != nil */ }
func test_provider_falls_back_to_cache() async {
    // cache has .week; fetcher throws -> entry.snapshot period week, stale true
}
func test_provider_no_cache_gives_error_entry() async {
    // empty cache, fetcher throws -> snapshot nil, error "No data from pve"
}
func testPeriodStoreRoundTrip() { /* default .day; set .month -> get .month */ }
```

- [ ] **Step 2: Run** `xcodebuild test ... -only-testing:PveWidgetTests/ProviderTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(app): snapshot client, cache, provider and period intent`.

---

### Task 7: Widget views, charts, app window, install

**Files:**
- Create: `app/Widgets/ThresholdLineChart.swift`, `PeriodSwitch.swift`, `HostWidgetView.swift`, `GuestsWidgetView.swift`, `PveWidgetBundle.swift`; complete `app/App/PveWidgetApp.swift`
- Test: `app/Tests/LayoutTests.swift`

**Interfaces:**
- Consumes: Tasks 5–6.
- Produces:
  - `func gradientStops(_ th: Threshold, yMax: Double) -> [Gradient.Stop]` — green `< warn`, yellow `warn…crit`, red `≥ crit`, hard edges (two stops per boundary at `warn/yMax`, `crit/yMax`, clamped to 0…1). Chart y domain `0...1`. Line = `LineMark` with `.foregroundStyle(LinearGradient(stops:, startPoint: .bottom, endPoint: .top))`; fill = `AreaMark` with the same stops at lower opacity.
  - `func guestGrid(_ guests: [Guest], max: Int = 8) -> (shown: [Guest], overflow: Int)`.
  - `PeriodSwitch(current: Period)` — three `Button(intent: SetPeriodIntent(period:))`, selected one highlighted.
  - Widgets: `HostWidget` (kind `"host"`) and `GuestsWidget` (kind `"guests"`), `.supportedFamilies([.systemExtraLarge])`, both use `SnapshotProvider`.
  - Layout per mockup `layout-b-v2.html`: Host = CPU chart (now big, avg, peak, load), RAM chart (used/total, swap), temps grid, storages bars, header with name, uptime and data time. Guests = 3-column card grid: name, type+VMID, CPU bar + mini chart + avg/peak, RAM, disk free (or "—"); stopped guests grey; stale entries show "data from HH:mm" in the header; error entry shows the error text centred.
  - Taps: `widgetURL(pvewidget://open?target=node/pve)` on Host; `Link(destination: pvewidget://open?target=<type>/<vmid>)` per guest card. The app's `onOpenURL` maps `target` to the pve UI URL in Global Constraints and opens it with `NSWorkspace.shared.open`, then stays in background.
  - App window: shows `HostWidgetView` and `GuestsWidgetView` side by side with a live fetch, for development.

- [ ] **Step 1: Write failing tests:**

```swift
func testGradientStops() {
    let s = gradientStops(.cpu, yMax: 1.0)
    XCTAssertEqual(s.map(\.location), [0, 0.70, 0.70, 0.90, 0.90, 1.0])
}
func test_guest_grid_overflow() {
    let g = (100...109).map(Guest.sample)        // sample factory in the test file
    let r = guestGrid(g); XCTAssertEqual(r.shown.map(\.vmid), Array(100...107)); XCTAssertEqual(r.overflow, 2)
    XCTAssertEqual(guestGrid(Array(g.prefix(6))).overflow, 0)
}
func testTargetURL() {
    XCTAssertEqual(pveURL(for: "qemu/102")?.absoluteString, "https://pve.example.ts.net:8006/#v1:0:=qemu%2F102")
}
```

`pveURL(for:) -> URL?` lives in `Shared/Format.swift` or a small `Shared/Links.swift`.

- [ ] **Step 2: Run** `xcodebuild test ... -only-testing:PveWidgetTests/LayoutTests` → FAIL.
- [ ] **Step 3: Implement** views, chart, switch, bundle, app.
- [ ] **Step 4: Run** full `xcodebuild test -project app/PveWidget.xcodeproj -scheme PveWidget -destination 'platform=macOS'` → all PASS.
- [ ] **Step 5: Build and install:** `xcodebuild -project app/PveWidget.xcodeproj -scheme PveWidget -configuration Release -derivedDataPath app/build build`, copy `app/build/Build/Products/Release/PveWidget.app` to `/Applications`, launch it once.
- [ ] **Step 6: Visual check:** take a screenshot of the app window (`screencapture -l <windowid>` or full screen) and compare with `layout-b-v2.html`: two panels, period switch on both, colored CPU line, 6 guest cards, temps and storages present.
- [ ] **Step 7: Ask the user** to add both widgets (Extra Large) to the desktop, tap `1w` on one and confirm both switch, tap a guest card and confirm the pve UI opens.
- [ ] **Step 8: Commit** `feat(app): host and guests widgets`.
