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
