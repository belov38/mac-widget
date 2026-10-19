import XCTest

private struct FakeFetcher: SnapshotFetching {
    var result: Result<Data, Error>
    func fetchData(_ p: Period) async throws -> Data { try result.get() }
}

private struct FakeError: Error, LocalizedError {
    var errorDescription: String? { "boom" }
}

final class ProviderTests: XCTestCase {
    private var dirs: [URL] = []

    override func tearDown() {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
        super.tearDown()
    }

    private func tempCache() -> SnapshotCache {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        dirs.append(dir)
        return SnapshotCache(dir: dir)
    }

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: ProviderTests.self).url(forResource: "snapshot.json", withExtension: nil))
        return try Data(contentsOf: url)
    }

    private let now = Date(timeIntervalSince1970: 1_792_366_300)

    func testProviderFreshFetchSavesCache() async throws {
        let cache = tempCache()
        let entry = await makeEntry(period: .day, fetcher: FakeFetcher(result: .success(try fixture())), cache: cache, now: now)
        XCTAssertFalse(entry.stale)
        XCTAssertNil(entry.error)
        XCTAssertNotNil(entry.snapshot)
        XCTAssertEqual(entry.date, now)
        XCTAssertNotNil(cache.load(.day))
    }

    func test_provider_falls_back_to_cache() async throws {
        let cache = tempCache()
        let weekData = Data(String(decoding: try fixture(), as: UTF8.self)
            .replacingOccurrences(of: "\"period\": \"day\"", with: "\"period\": \"week\"").utf8)
        cache.save(weekData, for: .week)
        let entry = await makeEntry(period: .day, fetcher: FakeFetcher(result: .failure(FakeError())), cache: cache, now: now)
        XCTAssertNotNil(entry.snapshot)
        XCTAssertTrue(entry.stale)
        XCTAssertEqual(entry.period, .day)
        XCTAssertEqual(entry.date, now)
        XCTAssertEqual(entry.error, "boom")
        XCTAssertEqual(entry.snapshot?.period, Period.week.rawValue)
    }

    func test_provider_prefers_own_period_cache() async throws {
        let cache = tempCache()
        cache.save(try fixture(), for: .day)
        let entry = await makeEntry(period: .day, fetcher: FakeFetcher(result: .failure(FakeError())), cache: cache, now: now)
        XCTAssertTrue(entry.stale)
        XCTAssertNotNil(entry.snapshot)
    }

    func test_provider_no_cache_gives_error_entry() async {
        let entry = await makeEntry(period: .day, fetcher: FakeFetcher(result: .failure(FakeError())), cache: tempCache(), now: now)
        XCTAssertNil(entry.snapshot)
        XCTAssertEqual(entry.error, "No data from pve")
    }

    func testCorruptCacheFileIsNil() throws {
        let cache = tempCache()
        cache.save(Data("not json".utf8), for: .day)
        XCTAssertNil(cache.load(.day))
        XCTAssertNil(cache.loadAny())
    }

    func testPeriodStoreRoundTrip() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        XCTAssertEqual(PeriodStore.get(d), .day)
        PeriodStore.set(.month, d)
        XCTAssertEqual(PeriodStore.get(d), .month)
    }
}
