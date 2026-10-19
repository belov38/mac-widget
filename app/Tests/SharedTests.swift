import XCTest

final class SharedTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: SharedTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: nil))
        return try Data(contentsOf: url)
    }

    func testDecodeGoldenSnapshot() throws {
        let s = try Snapshot.decode(fixture("snapshot.json"))
        XCTAssertEqual(s.guests.map(\.vmid), [100, 101, 102, 103, 104, 105])
        XCTAssertEqual(s.host.temps.first?.label, "CPU")
        XCTAssertNil(s.guests[0].disk)
        XCTAssertLessThanOrEqual(s.host.cpu.series.count, 96)
        XCTAssertEqual(s.generatedAt, Date(timeIntervalSince1970: 1792366260))
        XCTAssertEqual(s.host.cpu.series.first?.t, Date(timeIntervalSince1970: 1792280700))
        XCTAssertNil(s.guests[0].cpu.avg)
        let cpu = s.host.cpu.series
        XCTAssertTrue(cpu.allSatisfy { $0.max >= $0.avg })
        XCTAssertEqual(cpu.map(\.max).max(), s.host.cpu.peak)
    }

    func testDecodePointShapes() throws {
        let decoder = JSONDecoder()
        let full = try decoder.decode([Point].self, from: Data("[[10, 0.3, 0.92]]".utf8))
        XCTAssertEqual(full, [Point(t: Date(timeIntervalSince1970: 10), avg: 0.3, max: 0.92)])
        let legacy = try decoder.decode([Point].self, from: Data("[[10, 0.4]]".utf8))
        XCTAssertEqual(legacy, [Point(t: Date(timeIntervalSince1970: 10), avg: 0.4, max: 0.4)])
        XCTAssertThrowsError(try decoder.decode([Point].self, from: Data("[[10]]".utf8)))
    }

    func testDecodePointWithPressure() throws {
        let decoder = JSONDecoder()
        let p = try decoder.decode([Point].self, from: Data("[[10, 0.3, 0.92, 0.05, 0.2], [20, 0.1, 0.1, null, null]]".utf8))
        XCTAssertEqual(p[0], Point(t: Date(timeIntervalSince1970: 10), avg: 0.3, max: 0.92, pressureAvg: 0.05, pressureMax: 0.2))
        XCTAssertNil(p[1].pressureAvg)
        let data = try JSONEncoder().encode(p[0])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[10,0.3,0.92,0.05,0.2]")
    }

    func testDecodeSnapshotPressureFields() throws {
        let json = """
        {"generated_at": 1, "host": {"name": "pve", "uptime_s": 1, "cpus": 4, "load": [1],
          "cpu": {"now": 0.5, "avg": null, "peak": null, "series": [], "pressure": {"now": 0.12, "avg": 0.01, "peak": 0.3}},
          "mem": {"used": 1, "total": 2, "avg": null, "peak": null, "series": [], "pressure": {"now": null, "avg": null, "peak": null}},
          "swap": {"used": 0, "total": 0}, "io_pressure": {"now": 0.02, "avg": 0.01, "peak": 0.15},
          "temps": [], "storages": []},
         "guests": [{"vmid": 105, "type": "lxc", "name": "ct", "status": "running", "cpus": 1,
          "cpu": {"now": 0.1, "avg": null, "peak": null, "series": []}, "mem": {"used": 1, "total": 2},
          "mem_pressure": 0.02, "disk": null}]}
        """
        let s = try Snapshot.decode(Data(json.utf8))
        XCTAssertEqual(s.host.cpu.pressure?.now, 0.12)
        XCTAssertNil(s.host.mem.pressure?.now)
        XCTAssertEqual(s.host.ioPressure?.peak, 0.15)
        XCTAssertEqual(s.guests[0].memPressure, 0.02)
        XCTAssertNil(s.guests[0].cpu.pressure)
    }

    func testLevelRules() {
        // Host CPU: pressure decides, usage only without PSI.
        XCTAssertEqual(LevelRule.hostCPU.level(1.0, pressure: 0.02), .ok)
        XCTAssertEqual(LevelRule.hostCPU.level(0.2, pressure: 0.12), .warn)
        XCTAssertEqual(LevelRule.hostCPU.level(0.2, pressure: 0.3), .crit)
        XCTAssertEqual(LevelRule.hostCPU.level(0.95, pressure: nil), .crit)
        // Host memory: pressure, but near-full is red anyway.
        XCTAssertEqual(LevelRule.hostMem.level(0.92, pressure: 0), .ok)
        XCTAssertEqual(LevelRule.hostMem.level(0.96, pressure: 0), .crit)
        XCTAssertEqual(LevelRule.hostMem.level(0.5, pressure: 0.02), .warn)
        XCTAssertEqual(LevelRule.hostMem.level(0.92, pressure: nil), .warn)
    }

    func testGuestLevels() {
        func guest(_ type: String, cpu: Double, cpuPressure: Double?, mem: Int64, memPressure: Double?) -> Guest {
            Guest(vmid: 1, type: type, name: "g", status: "running", cpus: 2,
                  cpu: Metric(now: cpu, avg: nil, peak: nil, series: [],
                              pressure: cpuPressure.map { Pressure(now: $0) }),
                  mem: Usage(used: mem, total: 100), memPressure: memPressure, disk: nil)
        }
        // A busy VM stays red even without host-side pressure; a busy CT does not.
        XCTAssertEqual(guest("qemu", cpu: 0.95, cpuPressure: 0, mem: 10, memPressure: nil).cpuLevel, .crit)
        XCTAssertEqual(guest("lxc", cpu: 0.95, cpuPressure: 0, mem: 10, memPressure: nil).cpuLevel, .ok)
        // Host contention shows on an idle-looking VM.
        XCTAssertEqual(guest("qemu", cpu: 0.2, cpuPressure: 0.3, mem: 10, memPressure: nil).cpuLevel, .crit)
        // VM memory ignores host-side PSI; CT memory uses it.
        XCTAssertEqual(guest("qemu", cpu: 0, cpuPressure: nil, mem: 92, memPressure: 0).memLevel, .warn)
        XCTAssertEqual(guest("lxc", cpu: 0, cpuPressure: nil, mem: 92, memPressure: 0).memLevel, .ok)
        XCTAssertEqual(guest("lxc", cpu: 0, cpuPressure: nil, mem: 50, memPressure: 0.06).memLevel, .crit)
    }

    func testPointEncodesThreeElements() throws {
        let data = try JSONEncoder().encode(Point(t: Date(timeIntervalSince1970: 10), avg: 0.25, max: 0.5))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[10,0.25,0.5]")
    }

    func testThresholds() {
        XCTAssertEqual(Threshold.cpu.level(0.69), .ok)
        XCTAssertEqual(Threshold.cpu.level(0.70), .warn)
        XCTAssertEqual(Threshold.cpu.level(0.90), .crit)
        XCTAssertEqual(Temp(id: "dimm_a1", label: "DIMM A1", value: 56.5, warn: 55, crit: 85).level, .warn)
    }

    func testFormat() {
        XCTAssertEqual(Format.usage(45_327_728_640, 60_129_542_144), "42/56G")
        XCTAssertEqual(Format.usage(244_899_840, 2_147_483_648), "0.2/2G")
        XCTAssertEqual(Format.free(582_720_000_000, 832_000_000_000), "232G free")
        XCTAssertEqual(Format.percent(0.441), "44%")
        XCTAssertEqual(Period.allCases.map(\.label), ["24h", "1w", "1m"])
    }

    func testUsageRatio() {
        XCTAssertEqual(Usage(used: 1, total: 4).ratio, 0.25)
        XCTAssertEqual(Usage(used: 1, total: 0).ratio, 0)
    }

    func testMalformedGuestIsDropped() throws {
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("snapshot.json")) as? [String: Any])
        var guests = try XCTUnwrap(obj["guests"] as? [[String: Any]])
        guests[1]["cpus"] = NSNull()
        obj["guests"] = guests
        let s = try Snapshot.decode(JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(s.guests.map(\.vmid), [100, 102, 103, 104, 105])
    }

    func testStampShowsDateWhenNotToday() {
        let utc = TimeZone(identifier: "UTC")!
        let t = Date(timeIntervalSince1970: 1_792_366_260) // 2026-10-18 23:31 UTC
        XCTAssertEqual(Format.stamp(t, now: t.addingTimeInterval(600), utc), "23:31")
        XCTAssertEqual(Format.stamp(t, now: t.addingTimeInterval(3600), utc), "18 Oct 23:31")
    }

    func testStaleLabelIncludesDateWhenOld() throws {
        let snap = try Snapshot.decode(fixture("snapshot.json"))
        let utc = TimeZone(identifier: "UTC")!
        let entry = PveEntry(date: .now, period: .day, snapshot: snap, stale: true, error: nil)
        XCTAssertEqual(entry.staleLabel(now: snap.generatedAt.addingTimeInterval(60), tz: utc), "data from 23:31")
        XCTAssertEqual(entry.staleLabel(now: snap.generatedAt.addingTimeInterval(86_400), tz: utc), "data from 18 Oct 23:31")
        let fresh = PveEntry(date: .now, period: .day, snapshot: snap, stale: false, error: nil)
        XCTAssertNil(fresh.staleLabel(now: .now, tz: utc))
    }

    func testGuestCaptionsUseDataPeriod() {
        let same = guestStatCaptions(.sample(1), dataPeriod: .day, entryPeriod: .day)
        XCTAssertEqual(same.avg, "avg 10%")
        XCTAssertEqual(same.peak, "peak 20%")
        let fallback = guestStatCaptions(.sample(1), dataPeriod: .week, entryPeriod: .day)
        XCTAssertEqual(fallback.avg, "avg 1w 10%")
        XCTAssertEqual(fallback.peak, "peak 1w 20%")
    }

    func testQuitOnlyWithoutWindow() {
        XCTAssertTrue(shouldQuitAfterOpen(windowVisible: false))
        XCTAssertFalse(shouldQuitAfterOpen(windowVisible: true))
    }
}
