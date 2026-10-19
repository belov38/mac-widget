import Foundation

protocol SnapshotFetching: Sendable {
    /// Raw JSON body, returned so the caller can cache it as-is.
    func fetchData(_ p: Period) async throws -> Data
}

extension SnapshotFetching {
    func fetch(_ p: Period) async throws -> Snapshot {
        try Snapshot.decode(await fetchData(p))
    }
}

struct SnapshotError: Error, LocalizedError {
    let status: Int
    var errorDescription: String? { "HTTP \(status) from pve" }
}

struct SnapshotClient: SnapshotFetching {
    var baseURL = URL(string: "https://\(AppConfig.pveHost):9443")!

    func fetchData(_ p: Period) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent("v1/snapshot"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "period", value: p.rawValue)]
        var request = URLRequest(url: comps.url!)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw SnapshotError(status: status) }
        return data
    }
}
