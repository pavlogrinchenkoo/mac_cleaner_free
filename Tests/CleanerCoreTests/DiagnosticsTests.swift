import XCTest
@testable import CleanerCore

final class DiagnosticsTests: CleanerTestCase {
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
        XCTAssertTrue(text.contains("[✓ авто] 500 МБ"), text)
        XCTAssertTrue(text.contains("[  ] 300 МБ"))
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
        XCTAssertTrue(text.contains("com.adobe.Photoshop") && text.contains("4 ГБ"))
        XCTAssertTrue(text.contains("решта дрібніших"))
        XCTAssertTrue(text.contains("немає доступу"))
        XCTAssertTrue(text.contains("Було б: звільнено 0 КБ, у Кошик 500 МБ; пропущено 1"))
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

// MARK: - Мови звіту

final class DiagnosticsLocalizationTests: CleanerTestCase {
    private func entry(
        _ home: FakeHome, _ name: String, rule: String, bytes: Int64, scope: EntryScope = .home, locked: String? = nil,
        companions: [URL] = []
    ) -> Entry {
        var entry = Entry(ruleID: rule, url: home.path("Documents/\(name)"), lockedReason: locked, scope: scope, companions: companions)
        entry.measurement = DiskUsage(bytes: bytes, fileCount: 1, lastModified: Date().addingTimeInterval(-3 * 86_400), hadErrors: false)
        return entry
    }

    /// Звіт, у якому є всі класи елементів, правило з порогом, підсумок очищення й карта місця.
    private func richReport(_ home: FakeHome) throws -> String {
        let cache = try makeRule(id: "cache", paths: ["~/a"])
        let files = try makeRule(id: "files", paths: ["~/b"], extra: "\"moveToTrash\":true,\"bulkSelectable\":false")
        let admin = try makeRule(id: "admin", paths: ["~/c"], extra: "\"requiresAdmin\":true")
        let aged = try makeRule(id: "aged", paths: ["~/p"], extra: "\"autoSelectOlderThanDays\":30")
        let auto = entry(home, "auto.bin", rule: "cache", bytes: 500_000_000)
        let removed = entry(home, "removed.bin", rule: "cache", bytes: 300_000_000)
        let blocked = entry(home, "busy.bin", rule: "cache", bytes: 200_000_000, locked: "App is running")
        let manualOn = entry(home, "mine.psd", rule: "files", bytes: 100_000_000, scope: .userFile,
                             companions: [home.path("Documents/mine.xmp")])
        let unexplained = entry(home, "strange.psd", rule: "files", bytes: 95_000_000, scope: .userFile)
        let untouched = entry(home, "other.psd", rule: "files", bytes: 90_000_000, scope: .userFile)
        let system = entry(home, "sys.log", rule: "admin", bytes: 20_000_000)
        let fresh = entry(home, "fresh", rule: "aged", bytes: 70_000_000)
        let survey = [
            SurveySection(
                title: "~/Library/Caches", path: "/x",
                items: [SurveyItem(name: "big", bytes: 4_000_000_000, lastModified: Date(), children: [
                            SurveyItem(name: "inner", bytes: 2_000_000_000, lastModified: nil),
                            SurveyItem(name: "slow", bytes: 1_000_000_000, lastModified: nil, incomplete: true)]),
                        SurveyItem(name: "Mobile Documents", bytes: 0, lastModified: nil, note: "note"),
                        SurveyItem(name: "huge", bytes: 3_000_000_000, lastModified: nil, incomplete: true)],
                totalCount: 9, restBytes: 12_000_000, error: nil),
            SurveySection(title: "~/Downloads", path: "/y", items: [], totalCount: 0, restBytes: 0, error: "denied"),
        ]
        let apps = [DiagnosticApp(path: "/Applications/X.app", bundleID: "com.x", version: "1")]
        let report = CleanReport(items: [
            CleanItemResult(id: "a", path: home.path("Documents/auto.bin").path, outcome: .dryRun, disposal: .delete, bytes: 500_000_000),
            CleanItemResult(id: "b", path: home.path("Documents/b.mov").path, outcome: .skipped("skipped reason"), bytes: 0),
            CleanItemResult(id: "c", path: home.path("Documents/c.mov").path, outcome: .failed("failed reason"), bytes: 0),
        ], dryRun: true, logURL: nil)
        return DiagnosticReport.render(DiagnosticInput(
            appVersion: "1", dryRun: true, macOSVersion: "26", architecture: "arm64", fullDiskAccess: true,
            disk: DiskInfo(totalBytes: 500_000_000_000, freeBytes: 20_000_000_000), projectRoots: [],
            fileSettings: FileScanSettings(roots: [home.path("Documents")]),
            groups: [CleanupGroup(id: "g", title: "Group", symbol: "x")],
            results: [RuleResult(rule: cache, entries: [auto, removed, blocked]),
                      RuleResult(rule: files, entries: [manualOn, unexplained, untouched]),
                      RuleResult(rule: admin, entries: [system]), RuleResult(rule: aged, entries: [fresh])],
            selectedIDs: [auto.id, manualOn.id, unexplained.id], manualIDs: [removed.id, manualOn.id], ruleBlocks: [:],
            blockReason: { entry, _ in entry.lockedReason }, report: report, apps: apps, survey: survey, home: home.url))
    }

    private func legendLines(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("  [✓") }) else { return [] }
        return Array(lines[start..<min(start + 6, lines.count)])
    }

    func testUkrainianLegendColumnsAreUnchanged() throws {
        let text = try richReport(FakeHome())
        XCTAssertEqual(legendLines(text), [
            "  [✓ авто]            вибрано програмою за замовчуванням",
            "  [✓ ВРУЧНУ]          вибрав користувач (програма сама б не вибрала)",
            "  [✗ ЗНЯТО ВРУЧНУ]    програма вибрала б сама, але користувач зняв",
            "  [  ]                не вибрано (за замовчуванням тут лише вручну; причина в заголовку правила)",
            "  [✓ ???]             вибрано, але ні за замовчуванням, ні кліком (це була б помилка програми)",
            "  [🔒]                заблоковано: зараз вибрати не можна (причина вказана: програма запущена, остання версія…)",
        ])
    }

    func testEnglishLegendIsAlignedToTheSameColumn() throws {
        Loc.current = .en
        defer { Loc.current = .uk }
        let text = try richReport(FakeHome())
        XCTAssertEqual(legendLines(text), [
            "  [✓ auto]            selected by the app by default",
            "  [✓ MANUAL]          selected by the user (the app would not have selected it)",
            "  [✗ MANUAL OFF]      the app would have selected it, but the user unselected it",
            "  [  ]                not selected (manual-only by default; the reason is in the rule header)",
            "  [✓ ???]             selected, but neither by default nor by a click (this would be an app bug)",
            "  [🔒]                blocked: cannot be selected right now (reason given: app is running, latest version…)",
        ])
    }

    func testEnglishReportIsEnglishAndMatchesTheSharedMarkers() throws {
        Loc.current = .en
        defer { Loc.current = .uk }
        let text = try richReport(FakeHome())

        for expected in [
            "CLEANER — DIAGNOSTICS (dry run)", "Please review it before sending", "Full Disk Access: granted",
            "Disk: 20 GB free of 500 GB", "Project folders: none", "File search: ~/Documents", "Thresholds: large from 100 MB",
            "Found 8 item(s) (", "Selected AUTOMATICALLY (by default): 1 item(s), 500 MB.",
            "Added MANUALLY by the user: 1 item(s), 100 MB.",
            "Unselected MANUALLY (the app would have selected it): 1 item(s), 300 MB.",
            "Not selected because manual-only: ", "BLOCKED (cannot be selected right now): 1 item(s), 200 MB.",
            "TOTAL SELECTED NOW: 3 item(s): ", "Would be done: freed 500 MB, to Trash 0 KB; skipped 1, errors 1.",
            "  skipped: ~/Documents/b.mov — skipped reason", "  error: ~/Documents/c.mov — failed reason",
            "== FOUND (EVERYTHING the app saw) ==", "safe to remove", "→ Trash", "“select all” disabled", "admin password",
            "auto-select: only what has not changed for 30+ days", "blocked", "(+1 paths)", "3 days",
            "Largest items in key folders", "Not all sizes were fully measured (1)",
            "### ~/Library/Caches — 7.01 GB, items: 9", "the rest of the smaller ones: 12 MB", "└ ≥ 1 GB  slow", "≥ 3 GB  ", "huge",
        ] {
            XCTAssertTrue(text.contains(expected), "немає «\(expected)» у звіті:\n\(text)")
        }

        // Маркери, які шукає самоперевірка, — саме ті, що друкує звіт.
        XCTAssertEqual(DiagnosticMarkers.summaryHeader, "== SUMMARY ==")
        XCTAssertEqual(DiagnosticMarkers.surveyHeader, "== DISK USAGE MAP ==")
        XCTAssertEqual(DiagnosticMarkers.installedAppsHeader(count: 1), "== INSTALLED APPS (1) ==")
        for header in [DiagnosticMarkers.summaryHeader, DiagnosticMarkers.surveyHeader, DiagnosticMarkers.installedAppsHeader(count: 1)] {
            XCTAssertTrue(text.contains(header), header)
        }
        for marker in [DiagnosticMarkers.auto, DiagnosticMarkers.manualOn, DiagnosticMarkers.manualOff,
                       DiagnosticMarkers.unexplained, DiagnosticMarkers.notSelected, DiagnosticMarkers.blocked] {
            XCTAssertTrue(text.contains("  \(marker) "), "немає рядка з позначкою \(marker)")
        }
        let unexplainedLine = text.components(separatedBy: "\n").first { $0.hasPrefix("⚠︎") && $0.contains(DiagnosticMarkers.unexplainedPhrase) }
        XCTAssertNotNil(unexplainedLine, "підсумок про вибір невідомого походження має містити \(DiagnosticMarkers.unexplainedPhrase)")

        // Жоден український рядок цього звіту не «протік» в англійський.
        let spec = try NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:ll|l)?[d@]")
        for (english, ukrainian) in DiagnosticsStrings.uk {
            let range = NSRange(ukrainian.startIndex..., in: ukrainian)
            let masked = spec.stringByReplacingMatches(in: ukrainian, range: range, withTemplate: "\u{0}")
            for piece in masked.components(separatedBy: "\u{0}") where piece.count >= 6 && piece.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) {
                XCTAssertFalse(text.contains(piece), "український фрагмент «\(piece)» (ключ «\(english)») у англійському звіті")
            }
        }
    }

    func testUkrainianReportKeepsTheOriginalWording() throws {
        let text = try richReport(FakeHome())
        for expected in [
            "CLEANER — ДІАГНОСТИКА (пробний запуск)", "Full Disk Access: є", "Папки проєктів: немає", "Пошук файлів: ~/Documents",
            "== ПІДСУМОК ==", "== КАРТА ЗАЙНЯТОГО МІСЦЯ ==", "== ВСТАНОВЛЕНІ ПРОГРАМИ (1) ==",
            "Вибрано АВТОМАТИЧНО (за замовчуванням): 1 елементів, 500 МБ.", "Диск: вільно 20 ГБ з 500 ГБ",
            "⚠︎ Вибрано з НЕВІДОМОЇ причини", "(+1 шляхів)", "3 дн.", "### ~/Library/Caches — 7,01 ГБ, елементів: 9",
            "Було б: звільнено 500 МБ, у Кошик 0 КБ; пропущено 1, помилок 1.", "безпечно", "пароль",
        ] {
            XCTAssertTrue(text.contains(expected), "немає «\(expected)» у звіті:\n\(text)")
        }
        XCTAssertTrue(text.contains(DiagnosticMarkers.unexplainedPhrase))
    }
}
