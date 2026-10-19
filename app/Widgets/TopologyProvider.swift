import AppIntents
import Foundation
import WidgetKit

struct TopologyEntry: TimelineEntry {
    let date: Date
    let topology: Topology?
    /// True when showing cached data because the agent did not answer.
    let stale: Bool
    let error: String?
}

/// Fetch from the local agent and cache; fall back to the cached copy on failure.
func makeTopologyEntry(refresh: Bool = false, client: TopologyClient = TopologyClient(),
                       cache: TopologyCache = .production, now: Date = .now) async -> TopologyEntry {
    do {
        let data = try await client.fetchData(refresh: refresh)
        let topology = try Topology.decode(data)
        cache.save(data)
        return TopologyEntry(date: now, topology: topology, stale: false, error: nil)
    } catch {
        return TopologyEntry(date: now, topology: cache.load(), stale: true,
                             error: "tstopo agent: \(error.localizedDescription)")
    }
}

struct TopologyProvider: TimelineProvider {
    func placeholder(in context: Context) -> TopologyEntry {
        TopologyEntry(date: .now, topology: nil, stale: false, error: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (TopologyEntry) -> Void) {
        Task { completion(await makeTopologyEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<TopologyEntry>) -> Void) {
        Task {
            let entry = await makeTopologyEntry()
            completion(Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(300))))
        }
    }
}

/// Widget button: asks the agent for a fresh ping round, then reloads the topology widget.
struct RefreshTopologyIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Tailnet Topology"

    init() {}

    func perform() async throws -> some IntentResult {
        _ = await makeTopologyEntry(refresh: true)
        WidgetCenter.shared.reloadTimelines(ofKind: TopologyWidgetKind)
        return .result()
    }
}

let TopologyWidgetKind = "topology"
