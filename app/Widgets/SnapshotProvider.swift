import Foundation
import WidgetKit

struct PveEntry: TimelineEntry {
    let date: Date
    let period: Period
    let snapshot: Snapshot?
    let stale: Bool
    let error: String?
}

/// Fetch, cache and build an entry; fall back to cached data when the fetch fails.
func makeEntry(period: Period, fetcher: SnapshotFetching, cache: SnapshotCache, now: Date) async -> PveEntry {
    do {
        let data = try await fetcher.fetchData(period)
        let snapshot = try Snapshot.decode(data)
        cache.save(data, for: period)
        return PveEntry(date: now, period: period, snapshot: snapshot, stale: false, error: nil)
    } catch {
        if let cached = cache.load(period) ?? cache.loadAny() {
            return PveEntry(date: now, period: period, snapshot: cached, stale: true, error: error.localizedDescription)
        }
        return PveEntry(date: now, period: period, snapshot: nil, stale: true, error: "No data from pve")
    }
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> PveEntry {
        PveEntry(date: .now, period: .day, snapshot: .sample, stale: false, error: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (PveEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        let period = PeriodStore.get()
        Task {
            completion(await makeEntry(period: period, fetcher: SnapshotClient(), cache: .production, now: .now))
        }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<PveEntry>) -> Void) {
        let period = PeriodStore.get()
        Task {
            let now = Date.now
            let entry = await makeEntry(period: period, fetcher: SnapshotClient(), cache: .production, now: now)
            completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(300))))
        }
    }
}

extension Snapshot {
    /// Small realistic snapshot used for placeholders and previews.
    static let sample: Snapshot = {
        let t0 = Date(timeIntervalSince1970: 1_792_280_000)
        func series(_ base: Double) -> [Point] {
            (0..<24).map { i in
                let avg = min(max(base + 0.1 * sin(Double(i) / 3), 0), 1)
                return Point(t: t0.addingTimeInterval(Double(i) * 3600), avg: avg, max: min(avg + 0.08 * Double(i % 4), 1))
            }
        }
        let gib: Int64 = 1 << 30
        return Snapshot(
            schema: 1,
            generatedAt: t0.addingTimeInterval(86_400),
            period: "day",
            host: Host(
                name: "pve", uptimeS: 253_000, cpus: 24, load: [10.7, 9.2, 7.2],
                cpu: Metric(now: 0.44, avg: 0.31, peak: 0.92, series: series(0.4)),
                mem: HostMem(used: 100 * gib, total: 125 * gib, avg: 0.78, peak: 0.82, series: series(0.78)),
                swap: Usage(used: gib, total: 32 * gib),
                ioPressure: Pressure(now: 0.02, avg: 0.01, peak: 0.15),
                temps: [Temp(id: "cpu", label: "CPU", value: 62, warn: 85, crit: 95)],
                storages: [Storage(id: "vmdata", label: "vmdata", used: 800 * gib, total: 1580 * gib)]
            ),
            guests: [
                Guest(vmid: 100, type: "lxc", name: "dns", status: "running", cpus: 2,
                      cpu: Metric(now: 0.03, avg: 0.02, peak: 0.1, series: series(0.03)),
                      mem: Usage(used: gib / 4, total: 2 * gib),
                      disk: Disk(used: 3 * gib, total: 8 * gib, mount: "/")),
                Guest(vmid: 102, type: "qemu", name: "build", status: "running", cpus: 16,
                      cpu: Metric(now: 0.6, avg: 0.38, peak: 0.97, series: series(0.5)),
                      mem: Usage(used: 42 * gib, total: 56 * gib),
                      disk: Disk(used: 540 * gib, total: 775 * gib, mount: "/")),
                Guest(vmid: 104, type: "qemu", name: "test", status: "stopped", cpus: 4,
                      cpu: Metric(now: 0, avg: nil, peak: nil, series: []),
                      mem: Usage(used: 0, total: 8 * gib), disk: nil),
            ]
        )
    }()
}
