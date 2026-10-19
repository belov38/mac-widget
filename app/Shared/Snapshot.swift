import Foundation

struct Point: Sendable, Equatable, Codable {
    let t: Date
    /// Mean over the bucket.
    let avg: Double
    /// Peak within the bucket; equals avg when the collector has no peak data.
    let max: Double

    init(t: Date, avg: Double, max: Double) {
        self.t = t
        self.avg = avg
        self.max = max
    }

    // Decoded from [epoch seconds, avg, max] or the legacy [epoch seconds, value].
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        t = Date(timeIntervalSince1970: try c.decode(Double.self))
        avg = try c.decode(Double.self)
        max = c.isAtEnd ? avg : try c.decode(Double.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(t.timeIntervalSince1970)
        try c.encode(avg)
        try c.encode(max)
    }
}

struct Metric: Codable, Sendable, Equatable {
    var now: Double
    var avg: Double?
    var peak: Double?
    var series: [Point]
}

struct Usage: Codable, Sendable, Equatable {
    var used: Int64
    var total: Int64

    var ratio: Double { total > 0 ? Double(used) / Double(total) : 0 }

    private enum CodingKeys: String, CodingKey { case used, total }
}

/// Host memory: current usage plus period statistics.
struct HostMem: Codable, Sendable, Equatable {
    var used: Int64
    var total: Int64
    var avg: Double?
    var peak: Double?
    var series: [Point]

    var usage: Usage { Usage(used: used, total: total) }
    var ratio: Double { usage.ratio }
}

struct Disk: Codable, Sendable, Equatable {
    var used: Int64
    var total: Int64
    var mount: String?

    var usage: Usage { Usage(used: used, total: total) }
}

struct Temp: Codable, Sendable, Equatable {
    var id: String
    var label: String
    var value: Double
    var warn: Double
    var crit: Double
}

struct Storage: Codable, Sendable, Equatable {
    var id: String
    var label: String
    var used: Int64
    var total: Int64

    var usage: Usage { Usage(used: used, total: total) }
}

struct Host: Codable, Sendable, Equatable {
    var name: String
    var uptimeS: Int64
    var cpus: Int
    var load: [Double]
    var cpu: Metric
    var mem: HostMem
    var swap: Usage
    var temps: [Temp]
    var storages: [Storage]
}

struct Guest: Codable, Sendable, Equatable {
    var vmid: Int
    var type: String
    var name: String
    var status: String
    var cpus: Int
    var cpu: Metric
    var mem: Usage
    var disk: Disk?
}

struct Snapshot: Codable, Sendable, Equatable {
    var schema: Int?
    var generatedAt: Date
    var period: String?
    var host: Host
    var guests: [Guest]

    private enum CodingKeys: String, CodingKey { case schema, generatedAt, period, host, guests }

    init(schema: Int?, generatedAt: Date, period: String?, host: Host, guests: [Guest]) {
        self.schema = schema
        self.generatedAt = generatedAt
        self.period = period
        self.host = host
        self.guests = guests
    }

    // Guests are decoded one by one so a single malformed guest is dropped instead of failing the snapshot.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        period = try c.decodeIfPresent(String.self, forKey: .period)
        host = try c.decode(Host.self, forKey: .host)
        guests = try c.decode([LossyGuest].self, forKey: .guests).compactMap(\.guest)
    }

    private struct LossyGuest: Decodable {
        let guest: Guest?
        init(from decoder: Decoder) throws { guest = try? Guest(from: decoder) }
    }

    static func decode(_ data: Data) throws -> Snapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(Snapshot.self, from: data)
    }
}
