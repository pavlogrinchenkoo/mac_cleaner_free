import XCTest
@testable import CleanerCore

final class CleanEngineTests: CleanerTestCase {
    private func entries(for scanner: DiskScanner) -> [Entry] {
        scanner.discover().flatMap { result in
            result.entries.map { entry in
                var measured = entry
                measured.measurement = DiskSize.measure(entry.url)
                return measured
            }
        }
    }

    private func engine(_ home: FakeHome) -> CleanEngine {
        makeEngine(home)
    }

    func testDryRunDeletesNothing() throws {
        let home = try FakeHome()
        try home.makeFile("Library/Caches/App/data.bin", bytes: 50_000)
        let rule = try makeRule(paths: ["~/Library/Caches"])
        let scanner = DiskScanner(ruleSet: makeRuleSet([rule]), home: home.url)

        let report = engine(home).clean(entries: entries(for: scanner), rules: [rule], dryRun: true)
        XCTAssertTrue(home.exists("Library/Caches/App/data.bin"))
        XCTAssertGreaterThan(report.freedBytes, 0)
        XCTAssertNil(report.logURL)
    }

    func testRealCleanRemovesEntriesAndWritesLog() throws {
        let home = try FakeHome()
        try home.makeFile("Library/Caches/App/data.bin", bytes: 50_000)
        try home.makeFile("Library/Caches/Other/x/y.bin", bytes: 50_000)
        let rule = try makeRule(paths: ["~/Library/Caches"])
        let scanner = DiskScanner(ruleSet: makeRuleSet([rule]), home: home.url)

        let report = engine(home).clean(entries: entries(for: scanner), rules: [rule], dryRun: false)
        XCTAssertFalse(home.exists("Library/Caches/App"))
        XCTAssertFalse(home.exists("Library/Caches/Other"))
        XCTAssertTrue(home.exists("Library/Caches"), "сама папка Caches має лишитись")
        XCTAssertGreaterThanOrEqual(report.freedBytes, 100_000)
        let log = try String(contentsOf: XCTUnwrap(report.logURL), encoding: .utf8)
        XCTAssertTrue(log.contains("REMOVED"))
        XCTAssertTrue(log.contains("Library/Caches/App"))
    }

    func testSymlinkRemovalKeepsTarget() throws {
        let home = try FakeHome()
        let precious = try FakeHome()
        try precious.makeFile("important.txt")
        try FileManager.default.createDirectory(at: home.path("Library/Caches"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.path("Library/Caches/Link"), withDestinationURL: precious.url)
        let rule = try makeRule(paths: ["~/Library/Caches"])
        let scanner = DiskScanner(ruleSet: makeRuleSet([rule]), home: home.url)

        _ = engine(home).clean(entries: entries(for: scanner), rules: [rule], dryRun: false)
        XCTAssertFalse(home.exists("Library/Caches/Link"))
        XCTAssertTrue(precious.exists("important.txt"), "ціль symlink-а не можна чіпати")
    }

    func testReadOnlyDirectoriesAreRemoved() throws {
        let home = try FakeHome()
        try home.makeFile("Library/Caches/App/sub/file.bin", bytes: 10_000)
        chmod(home.path("Library/Caches/App/sub").path, 0o555)
        let rule = try makeRule(paths: ["~/Library/Caches"])
        let scanner = DiskScanner(ruleSet: makeRuleSet([rule]), home: home.url)

        let report = engine(home).clean(entries: entries(for: scanner), rules: [rule], dryRun: false)
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertFalse(home.exists("Library/Caches/App"))
    }

    func testLockedEntriesAreSkipped() throws {
        let home = try FakeHome()
        try home.makeFile("Library/Caches/Google/AndroidStudio2026.2.3/f")
        try home.makeFile("Library/Caches/Google/AndroidStudio2025.3.1/f")
        let rule = try makeRule(paths: ["~/Library/Caches/Google/*"], granularity: "self", extra: "\"keepNewestVersion\":true")
        let scanner = DiskScanner(ruleSet: makeRuleSet([rule]), home: home.url)

        let report = engine(home).clean(entries: entries(for: scanner), rules: [rule], dryRun: false)
        XCTAssertTrue(home.exists("Library/Caches/Google/AndroidStudio2026.2.3"))
        XCTAssertFalse(home.exists("Library/Caches/Google/AndroidStudio2025.3.1"))
        XCTAssertEqual(report.skipped.count, 1)
    }

    func testGuardStopsForgedEntries() throws {
        let home = try FakeHome()
        try home.makeFile("Documents/thesis.txt")
        let outside = try FakeHome()
        try outside.makeFile("victim.txt")
        let rule = try makeRule(paths: ["~/Library/Caches"])

        // Even if someone slips in an "entry" for Documents or outside the home folder, the engine must refuse.
        var forgedDocs = Entry(ruleID: rule.id, url: home.path("Documents/thesis.txt"))
        forgedDocs.measurement = DiskUsage(bytes: 1, fileCount: 1, lastModified: nil, hadErrors: false)
        var forgedOutside = Entry(ruleID: rule.id, url: outside.path("victim.txt"))
        forgedOutside.measurement = forgedDocs.measurement
        var forgedHome = Entry(ruleID: rule.id, url: home.url)
        forgedHome.measurement = forgedDocs.measurement

        let report = engine(home).clean(entries: [forgedDocs, forgedOutside, forgedHome], rules: [rule], dryRun: false)
        XCTAssertEqual(report.skipped.count, 3)
        XCTAssertTrue(home.exists("Documents/thesis.txt"))
        XCTAssertTrue(outside.exists("victim.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.url.path))
    }

    func testAlreadyGoneEntryIsSkippedNotFailed() throws {
        let home = try FakeHome()
        try home.makeFile("Library/Caches/App/f")
        let rule = try makeRule(paths: ["~/Library/Caches"])
        let scanner = DiskScanner(ruleSet: makeRuleSet([rule]), home: home.url)
        let found = entries(for: scanner)
        try FileManager.default.removeItem(at: home.path("Library/Caches/App"))

        let report = engine(home).clean(entries: found, rules: [rule], dryRun: false)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.skipped.count, 1)
    }
}
