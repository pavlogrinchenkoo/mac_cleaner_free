import XCTest
@testable import CleanerCore

final class DiagnosticsTests: XCTestCase {
    private func input(
        home: FakeHome, results: [RuleResult], selected: Set<String> = [], apps: [DiagnosticApp] = [],
        survey: [SurveySection] = [], report: CleanReport? = nil
    ) -> DiagnosticInput {
        DiagnosticInput(
            appVersion: "9.9", generatedAt: Date(), dryRun: true, macOSVersion: "26.1.0", architecture: "arm64",
            fullDiskAccess: false, disk: DiskInfo(totalBytes: 500_000_000_000, freeBytes: 20_000_000_000),
            projectRoots: [home.path("Projects")], fileSettings: nil,
            groups: [CleanupGroup(id: "g", title: "Група", symbol: "gear")], results: results, selectedIDs: selected,
            ruleBlocks: [:],
            blockReason: { entry, _ in entry.lockedReason }, report: report, apps: apps, survey: survey, home: home.url)
    }

    private func entry(_ home: FakeHome, _ relative: String, rule: String, bytes: Int64, locked: String? = nil) -> Entry {
        var entry = Entry(ruleID: rule, url: home.path(relative), lockedReason: locked)
        entry.measurement = DiskUsage(bytes: bytes, fileCount: 1, lastModified: Date().addingTimeInterval(-3 * 86_400), hadErrors: false)
        return entry
    }

    func testReportHasHeaderSelectionLocksAndFlags() throws {
        let home = try FakeHome()
        let trash = try makeRule(id: "files.x", paths: ["~/a"], extra: "\"moveToTrash\":true")
        let selectedEntry = entry(home, "Documents/a.mov", rule: trash.id, bytes: 500_000_000)
        let plain = entry(home, "Documents/b.mov", rule: trash.id, bytes: 300_000_000)
        let locked = entry(home, "Documents/c.mov", rule: trash.id, bytes: 100_000_000, locked: "Застосунок запущений")
        let text = DiagnosticReport.render(input(
            home: home, results: [RuleResult(rule: trash, entries: [selectedEntry, plain, locked])], selected: [selectedEntry.id]))

        XCTAssertTrue(text.contains("ДІАГНОСТИКА (пробний запуск)"))
        XCTAssertTrue(text.contains("Перегляньте його перед відправкою"), "попередження про приватність")
        XCTAssertTrue(text.contains("Full Disk Access: немає"))
        XCTAssertTrue(text.contains("macOS: 26.1.0"))
        XCTAssertTrue(text.contains("[✓ авто] 500 MB"), text)
        XCTAssertTrue(text.contains("[  ] 300 MB"))
        XCTAssertTrue(text.contains("[🔒]") && text.contains("Застосунок запущений"))
        XCTAssertTrue(text.contains("→ Кошик"))
        XCTAssertTrue(text.contains("~/Documents/a.mov"), "шляхи скорочуються до ~")
        XCTAssertFalse(text.contains(home.url.path), "повний шлях до домашньої папки не світимо")
    }

    func testLongListsAreCappedWithSummary() throws {
        let home = try FakeHome()
        let rule = try makeRule(id: "r", paths: ["~/a"])
        let entries = (0..<650).map { entry(home, "Documents/f\($0).bin", rule: "r", bytes: Int64(1_000_000 + $0)) }
        let text = DiagnosticReport.render(input(home: home, results: [RuleResult(rule: rule, entries: entries)]))
        XCTAssertTrue(text.contains("… ще 50 елементів"))
        XCTAssertEqual(text.components(separatedBy: "~/Documents/f").count - 1, 600)
    }

    func testReportIncludesAppsSurveyAndDryRunResults() throws {
        let home = try FakeHome()
        let survey = [SurveySection(
            title: "~/Library/Caches", path: "/x",
            items: [SurveyItem(name: "com.adobe.Photoshop", bytes: 4_000_000_000, lastModified: Date())],
            totalCount: 9, restBytes: 12_000_000, error: nil),
            SurveySection(title: "~/Downloads", path: "/y", items: [], totalCount: 0, restBytes: 0, error: "немає доступу (потрібен Full Disk Access)")]
        let apps = [DiagnosticApp(path: "/Applications/Adobe Photoshop 2025/Adobe Photoshop 2025.app", bundleID: "com.adobe.Photoshop", version: "26.0")]
        let report = CleanReport(items: [
            CleanItemResult(id: "a", path: home.path("Documents/a.mov").path, outcome: .dryRun, disposal: .trash, bytes: 500_000_000),
            CleanItemResult(id: "b", path: home.path("Documents/b.mov").path, outcome: .skipped("Оригінал змінився"), bytes: 0),
        ], dryRun: true, logURL: nil)
        let text = DiagnosticReport.render(input(home: home, results: [], apps: apps, survey: survey, report: report))

        XCTAssertTrue(text.contains("ВСТАНОВЛЕНІ ПРОГРАМИ (1)"))
        XCTAssertTrue(text.contains("com.adobe.Photoshop  26.0"))
        XCTAssertTrue(text.contains("КАРТА ЗАЙНЯТОГО МІСЦЯ"))
        XCTAssertTrue(text.contains("com.adobe.Photoshop") && text.contains("4 GB"))
        XCTAssertTrue(text.contains("решта дрібніших"))
        XCTAssertTrue(text.contains("немає доступу"))
        XCTAssertTrue(text.contains("Було б: звільнено 0 КБ, у Кошик 500 MB; пропущено 1"))
        XCTAssertTrue(text.contains("пропущено: ~/Documents/b.mov — Оригінал змінився"))
    }

    func testSurveyMeasuresSortsAndSkips() throws {
        let home = try FakeHome()
        try home.makeFile("Lib/small/a", bytes: 10_000)
        try home.makeFile("Lib/large/a", bytes: 500_000)
        try home.makeFile("Lib/medium/a", bytes: 100_000)
        try home.makeFile("Lib/skipme/a", bytes: 900_000)
        let directories = [
            SurveyDirectory(title: "Lib", url: home.path("Lib"), skip: [home.path("Lib/skipme").path]),
            SurveyDirectory(title: "Немає", url: home.path("Missing")),
        ]
        let sections = DiskSurvey.run(home: home.url, directories: directories)
        XCTAssertEqual(sections[0].items.map(\.name), ["large", "medium", "small"])
        XCTAssertEqual(sections[0].totalCount, 3)
        XCTAssertNil(sections[0].error)
        XCTAssertNil(sections[1].error, "відсутня тека не є помилкою")
        XCTAssertTrue(sections[1].items.isEmpty)
    }

    func testSurveyCapsTopItemsAndSumsTheRest() throws {
        let home = try FakeHome()
        for i in 0..<(DiskSurvey.topPerSection + 5) { try home.makeFile("Lib/item\(i)/a", bytes: 5_000) }
        let section = try XCTUnwrap(DiskSurvey.run(home: home.url, directories: [SurveyDirectory(title: "Lib", url: home.path("Lib"))]).first)
        XCTAssertEqual(section.items.count, DiskSurvey.topPerSection)
        XCTAssertEqual(section.totalCount, DiskSurvey.topPerSection + 5)
        XCTAssertGreaterThan(section.restBytes, 0)
    }

    func testSurveyReportsUnreadableFolders() throws {
        let home = try FakeHome()
        try home.makeFile("Locked/a", bytes: 5_000)
        chmod(home.path("Locked").path, 0o000)
        defer { chmod(home.path("Locked").path, 0o755) }
        let section = try XCTUnwrap(DiskSurvey.run(home: home.url, directories: [SurveyDirectory(title: "Locked", url: home.path("Locked"))]).first)
        XCTAssertNotNil(section.error)
    }

    func testDefaultSurveyDirectoriesDoNotOverlap() throws {
        let home = try FakeHome()
        let directories = DiskSurvey.directories(home: home.url)
        let rest = try XCTUnwrap(directories.first { $0.title.hasPrefix("~ (решта") })
        XCTAssertTrue(rest.skip.contains(home.path("Library").path), "Library розглядається окремо")
        XCTAssertTrue(rest.skip.contains(home.path("Documents").path))
        let libraryRest = try XCTUnwrap(directories.first { $0.title.hasPrefix("~/Library (решта") })
        XCTAssertTrue(libraryRest.skip.contains(home.path("Library/Caches").path))
    }

    func testWriteStoresFileInLogsFolder() throws {
        let home = try FakeHome()
        let url = try XCTUnwrap(DiagnosticReport.write("текст", home: home.url, dryRun: true))
        XCTAssertTrue(url.path.contains("Library/Application Support/Cleaner/logs/"))
        XCTAssertTrue(url.lastPathComponent.hasPrefix("dryrun-") && url.pathExtension == "txt")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "текст")
    }

    func testInstalledAppsFindsNestedAdobeFolders() throws {
        let home = try FakeHome()
        try makeApp(home, at: "Apps/Figma.app", bundleID: "com.figma.Desktop", name: "Figma")
        try makeApp(home, at: "Apps/Adobe Photoshop 2025/Adobe Photoshop 2025.app", bundleID: "com.adobe.Photoshop", name: "Adobe Photoshop 2025")
        let apps = DiagnosticReport.installedApps(roots: [home.path("Apps")])
        XCTAssertEqual(apps.map(\.bundleID).sorted(), ["com.adobe.Photoshop", "com.figma.Desktop"])
    }
}
