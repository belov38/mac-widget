import SwiftUI
import XCTest

extension Guest {
    static func sample(_ vmid: Int) -> Guest {
        Guest(vmid: vmid, type: "qemu", name: "vm-\(vmid)", status: "running", cpus: 2,
              cpu: Metric(now: 0.1, avg: 0.1, peak: 0.2, series: []),
              mem: Usage(used: 1 << 30, total: 2 << 30), disk: nil)
    }
}

final class LayoutTests: XCTestCase {
    private func point(_ avg: Double, _ max: Double) -> Point {
        Point(t: Date(timeIntervalSince1970: 0), avg: avg, max: max)
    }

    func testBarSegmentsAvgAndMax() {
        XCTAssertEqual(barSegments(point(0.3, 0.92), .cpu),
                       [BarSegment(from: 0, to: 0.3, level: .ok), BarSegment(from: 0.3, to: 0.92, level: .crit)])
        XCTAssertEqual(barSegments(point(0.75, 0.85), .cpu),
                       [BarSegment(from: 0, to: 0.75, level: .warn), BarSegment(from: 0.75, to: 0.85, level: .warn)])
    }

    func testBarSegmentsSingleWhenMaxEqualsAvg() {
        XCTAssertEqual(barSegments(point(0.5, 0.5), .cpu), [BarSegment(from: 0, to: 0.5, level: .ok)])
        // A max below avg is treated as equal.
        XCTAssertEqual(barSegments(point(0.5, 0.4), .cpu), [BarSegment(from: 0, to: 0.5, level: .ok)])
    }

    func testBarSegmentsClamped() {
        XCTAssertEqual(barSegments(point(0.96, 1.3), .mem),
                       [BarSegment(from: 0, to: 0.96, level: .crit), BarSegment(from: 0.96, to: 1, level: .crit)])
        XCTAssertEqual(barSegments(point(1.2, 1.5), .cpu), [BarSegment(from: 0, to: 1, level: .crit)])
        XCTAssertEqual(barSegments(point(-0.1, 0.2), .cpu),
                       [BarSegment(from: 0, to: 0, level: .ok), BarSegment(from: 0, to: 0.2, level: .ok)])
    }

    func testBarSegmentsColoredByPressure() {
        let p = Point(t: Date(timeIntervalSince1970: 0), avg: 0.95, max: 1.0, pressureAvg: 0.01, pressureMax: 0.3)
        XCTAssertEqual(barSegments(p, LevelRule.hostCPU),
                       [BarSegment(from: 0, to: 0.95, level: .ok), BarSegment(from: 0.95, to: 1, level: .crit)])
        // Buckets without PSI fall back to usage.
        XCTAssertEqual(barSegments(point(0.95, 0.95), LevelRule.hostCPU), [BarSegment(from: 0, to: 0.95, level: .crit)])
    }

    func testBarSlotsFillWidthWithGap() {
        let slots = barSlots(count: 4, width: 100)
        XCTAssertEqual(slots.count, 4)
        XCTAssertEqual(slots.first?.minX, 0)
        XCTAssertEqual(slots.last?.maxX, 100)
        XCTAssertEqual(slots[1].minX - slots[0].maxX, 1)
        XCTAssertTrue(slots.allSatisfy { $0.width > 0 })
        XCTAssertTrue(barSlots(count: 0, width: 100).isEmpty)
    }

    func test_guest_grid_overflow() {
        let g = (100...109).map(Guest.sample)
        let r = guestGrid(g)
        XCTAssertEqual(r.shown.map(\.vmid), Array(100...107))
        XCTAssertEqual(r.overflow, 2)
        XCTAssertEqual(guestGrid(Array(g.prefix(6))).overflow, 0)
    }

    func testTargetURL() {
        XCTAssertEqual(pveURL(for: "qemu/102")?.absoluteString, "https://\(AppConfig.pveHost):8006/#v1:0:=qemu%2F102")
        XCTAssertEqual(pveURL(for: "node/pve")?.absoluteString, "https://\(AppConfig.pveHost):8006/#v1:0:=node%2Fpve")
        XCTAssertNil(pveURL(for: "evil/../x#y"))
    }

    func testOpenURLRoundTrip() {
        let url = widgetOpenURL(target: "lxc/104")
        XCTAssertEqual(url.absoluteString, "pvewidget://open?target=lxc/104")
        XCTAssertEqual(openTarget(from: url), "lxc/104")
        XCTAssertNil(openTarget(from: URL(string: "https://example.com/?target=lxc/104")!))
    }

    func testUptimeAndTime() {
        XCTAssertEqual(Format.uptime(255_291), "2d 22h")
        XCTAssertEqual(Format.uptime(18_720), "5h 12m")
        XCTAssertEqual(Format.time(Date(timeIntervalSince1970: 1_792_366_260), TimeZone(identifier: "UTC")!), "23:31")
    }
}
