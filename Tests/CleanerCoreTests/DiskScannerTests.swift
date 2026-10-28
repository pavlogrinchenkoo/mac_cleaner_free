import XCTest
@testable import CleanerCore

final class DiskScannerTests: CleanerTestCase {
    private func scan(_ scanner: DiskScanner) async -> [String: RuleResult] {
        var results: [String: RuleResult] = [:]
        for await event in scanner.scan() {
            switch event {
            case .discovered(let found):
                results = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
            case .appended(let found):
                for result in found { results[result.id] = result }
            case .measured(let id, let measurement):
                for key in results.keys {
                    if let index = results[key]?.entries.firstIndex(where: { $0.id == id }) {
                        results[key]?.entries[index].measurement = measurement
                    }
                }
            case .status: break
            case .finished: break
            }
        }
        return results
    }

    func testChildrenGranularityAndSizes() async throws {
        let home = try FakeHome()
        try home.makeFile("Library/Developer/Xcode/DerivedData/AppA/x.bin", bytes: 300_000)
        try home.makeFile("Library/Developer/Xcode/DerivedData/AppB/x.bin", bytes: 100_000)
        let rule = try makeRule(paths: ["~/Library/Developer/Xcode/DerivedData"])
        let results = await scan(DiskScanner(ruleSet: makeRuleSet([rule]), home: home.url))

        let entries = try XCTUnwrap(results[rule.id]).entries
        XCTAssertEqual(entries.map(\.name), ["AppA", "AppB"])
        XCTAssertGreaterThanOrEqual(entries[0].bytes, 300_000)
        XCTAssertGreaterThanOrEqual(entries[1].bytes, 100_000)
        XCTAssertLessThan(entries[1].bytes, entries[0].bytes)
    }

    func testMissingPathsProduceNoEntries() async throws {
        let home = try FakeHome()
        let rule = try makeRule(paths: ["~/Library/Caches/Nothing"])
        let results = await scan(DiskScanner(ruleSet: makeRuleSet([rule]), home: home.url))
        XCTAssertTrue(try XCTUnwrap(results[rule.id]).entries.isEmpty)
    }

    func testKeepNewestVersionLocksNewestAndSkipsUnversioned() throws {
        let home = try FakeHome()
        for name in ["AndroidStudio2025.3.4", "AndroidStudio2026.2.3", "AndroidStudio2026.1.4", "Chrome"] {
            try home.makeFile("Library/Caches/Google/\(name)/f")
        }
        let rule = try makeRule(paths: ["~/Library/Caches/Google/*"], granularity: "self", extra: "\"keepNewestVersion\":true")
        let entries = DiskScanner(ruleSet: makeRuleSet([rule]), home: home.url).discover()[0].entries

        XCTAssertEqual(entries.count, 3, "Chrome без версії має відпасти")
        XCTAssertEqual(entries.filter { $0.lockedReason != nil }.map(\.name), ["AndroidStudio2026.2.3"])
    }

    func testRecentlyUsedEntriesAreBlocked() throws {
        let home = try FakeHome()
        let rule = try makeRule(paths: ["~/x/*"], granularity: "self", extra: "\"protectRecentDays\":30")
        var fresh = Entry(ruleID: rule.id, url: home.path("x/fresh"))
        fresh.measurement = DiskUsage(bytes: 10, fileCount: 1, lastModified: Date().addingTimeInterval(-2 * 86_400), hadErrors: false)
        var old = Entry(ruleID: rule.id, url: home.path("x/old"))
        old.measurement = DiskUsage(bytes: 10, fileCount: 1, lastModified: Date().addingTimeInterval(-90 * 86_400), hadErrors: false)

        let snapshot = RunningSnapshot()
        XCTAssertNotNil(DiskScanner.blockReason(for: fresh, rule: rule, ruleBlock: nil, snapshot: snapshot))
        XCTAssertNil(DiskScanner.blockReason(for: old, rule: rule, ruleBlock: nil, snapshot: snapshot))
    }

    func testCatchAllSkipsWhatSpecificRulesClaimed() async throws {
        let home = try FakeHome()
        try home.makeFile("Library/Caches/Yarn/v6/a")
        try home.makeFile("Library/Caches/Google/AndroidStudio1/a")
        try home.makeFile("Library/Caches/Google/Chrome/a")
        try home.makeFile("Library/Caches/SomeApp/a")
        try home.makeFile("Library/Caches/com.apple.Safari/a")
        try home.makeFile("Library/Caches/.DS_Store")

        let yarn = try makeRule(id: "yarn", paths: ["~/Library/Caches/Yarn"])
        let studio = try makeRule(id: "studio", paths: ["~/Library/Caches/Google/AndroidStudio*"], granularity: "self")
        let catchAll = try makeRule(id: "rest", paths: ["~/Library/Caches"], extra: "\"catchAll\":true,\"excludeNames\":[\"com.apple.*\"]")
        let results = DiskScanner(ruleSet: makeRuleSet([catchAll, yarn, studio]), home: home.url).discover()

        let rest = try XCTUnwrap(results.first { $0.id == "rest" })
        // Yarn and Google are covered by more specific rules; com.apple.* is excluded; .DS_Store is a system file.
        XCTAssertEqual(rest.entries.map(\.name), ["SomeApp"])
    }

    func testRunningAppCacheDetection() {
        let snapshot = RunningSnapshot(bundleIDs: ["com.google.Chrome"], appNames: ["spotify"])
        XCTAssertTrue(snapshot.ownsCache(named: "com.google.Chrome"))
        XCTAssertTrue(snapshot.ownsCache(named: "com.google.Chrome.helper"))
        XCTAssertTrue(snapshot.ownsCache(named: "Spotify"))
        XCTAssertFalse(snapshot.ownsCache(named: "com.google.Chromium"))
        XCTAssertFalse(snapshot.ownsCache(named: "SomethingElse"))
    }
}
