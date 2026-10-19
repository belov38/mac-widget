import Foundation

/// Path the Mac used to reach a node, from `tailscale ping`.
struct TPath: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case lan, direct, derp, peerRelay = "peer_relay"
    }

    struct First: Codable, Sendable, Equatable {
        var kind: Kind
        var via: String
        var ms: Double
    }

    var kind: Kind
    /// "ip:port" for direct paths, region code for DERP.
    var via: String
    /// Median over the pongs on this path.
    var ms: Double
    var minMs: Double?
    var maxMs: Double?
    var n: Int?
    /// Path of the first pong when it differs from the final one (link was warming up).
    var first: First?
}

struct TNode: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var os: String
    var online: Bool
    var lastSeen: String?
    var derp: String?
    var ip: String?
    /// "pve" for guests running on the pve host.
    var parent: String?
    var exitNode: Bool?
    var path: TPath?
    var error: String?

    var lastSeenDate: Date? { lastSeen.flatMap(parseISODate) }
}

struct TSelf: Codable, Sendable, Equatable {
    var name: String
    var os: String
    var derp: String?
    var lan: [String]
    var udp: Bool?
    var ipv6: Bool?
    var hardNat: Bool?
    var preferredDerp: String?
    var derpMs: Double?
    var publicAddr: String?
}

struct Topology: Codable, Sendable, Equatable {
    var schema: Int
    var generatedAt: String
    var me: TSelf
    var nodes: [TNode]

    private enum CodingKeys: String, CodingKey {
        case schema, generatedAt, me = "self", nodes
    }

    var generatedDate: Date { parseISODate(generatedAt) ?? .distantPast }

    static func decode(_ data: Data) throws -> Topology {
        try JSONDecoder().decode(Topology.self, from: data)
    }
}

/// ISO 8601 with or without fractional seconds (Tailscale emits both).
func parseISODate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

struct TopologyClient: Sendable {
    var baseURL = URL(string: "http://127.0.0.1:9185")!

    /// Raw JSON from the local agent; `refresh` forces a new ping round (takes up to ~20 s).
    func fetchData(refresh: Bool = false) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent("v1/topology"), resolvingAgainstBaseURL: false)!
        if refresh { comps.queryItems = [URLQueryItem(name: "refresh", value: "1")] }
        var request = URLRequest(url: comps.url!)
        request.timeoutInterval = refresh ? 40 : 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw TopologyError(message: "HTTP \(status) from tstopo agent") }
        return data
    }
}

struct TopologyError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Last good topology in the App Group container, shown when the agent is unreachable.
struct TopologyCache: Sendable {
    let url: URL

    static var production: TopologyCache {
        let fm = FileManager.default
        let base = fm.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id)
            ?? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return TopologyCache(url: base.appendingPathComponent("snapshots/topology.json"))
    }

    func save(_ data: Data) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func load() -> Topology? {
        (try? Data(contentsOf: url)).flatMap { try? Topology.decode($0) }
    }
}
