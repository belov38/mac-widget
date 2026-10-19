import Foundation

/// Values injected from Config.xcconfig through Info.plist.
enum AppConfig {
    static let pveHost = info("PVEHost")
    static let appGroupID = info("AppGroupID")

    private static func info(_ key: String) -> String {
        guard let v = Bundle.main.object(forInfoDictionaryKey: key) as? String, !v.isEmpty else {
            fatalError("\(key) is missing from Info.plist; check Config.xcconfig")
        }
        return v
    }
}

enum AppGroup {
    static let id = AppConfig.appGroupID
}

extension UserDefaults {
    // UserDefaults is thread-safe; the static is safe to share.
    nonisolated(unsafe) static let group = UserDefaults(suiteName: AppGroup.id)!
}

enum PeriodStore {
    private static let key = "period"

    static func get(_ d: UserDefaults = .group) -> Period {
        d.string(forKey: key).flatMap(Period.init(rawValue:)) ?? .day
    }

    static func set(_ p: Period, _ d: UserDefaults = .group) {
        d.set(p.rawValue, forKey: key)
    }
}

struct SnapshotCache: Sendable {
    let dir: URL

    init(dir: URL) { self.dir = dir }

    /// Cache in the App Group container, falling back to the caches directory.
    static var production: SnapshotCache {
        let fm = FileManager.default
        let base = fm.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id)
            ?? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return SnapshotCache(dir: base.appendingPathComponent("snapshots", isDirectory: true))
    }

    private func url(_ p: Period) -> URL {
        dir.appendingPathComponent("snapshot-\(p.rawValue).json")
    }

    func save(_ data: Data, for p: Period) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url(p), options: .atomic)
    }

    func load(_ p: Period) -> Snapshot? {
        guard let data = try? Data(contentsOf: url(p)) else { return nil }
        return try? Snapshot.decode(data)
    }

    /// Newest decodable cached snapshot of any period.
    func loadAny() -> Snapshot? {
        let dated: [(Period, Date)] = Period.allCases.compactMap { p in
            let values = try? url(p).resourceValues(forKeys: [.contentModificationDateKey])
            return values?.contentModificationDate.map { (p, $0) }
        }
        for (p, _) in dated.sorted(by: { $0.1 > $1.1 }) {
            if let s = load(p) { return s }
        }
        return nil
    }
}
