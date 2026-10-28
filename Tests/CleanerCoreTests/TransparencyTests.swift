import XCTest
@testable import CleanerCore

final class DefaultDecisionTests: CleanerTestCase {
    private func entry(scope: EntryScope = .home, daysAgo: Double? = 1) -> Entry {
        var entry = Entry(ruleID: "r", url: URL(fileURLWithPath: "/tmp/x"), scope: scope)
        entry.measurement = DiskUsage(
            bytes: 10, fileCount: 1, lastModified: daysAgo.map { Date().addingTimeInterval(-$0 * 86_400) }, hadErrors: false)
        return entry
    }

    func testReasonsAreSpecific() throws {
        let safe = try makeRule(paths: ["~/a"])
        XCTAssertEqual(DiskScanner.defaultDecision(entry(), rule: safe), .init(selected: true, reason: "безпечний кеш"))

        let careful = try JSONDecoder().decode(CleanupRule.self, from: Data(
            #"{"id":"c","group":"g","title":"T","detail":"D","risk":"careful","paths":["~/a"]}"#.utf8))
        XCTAssertEqual(DiskScanner.defaultDecision(entry(), rule: careful).selected, false)
        XCTAssertTrue(DiskScanner.defaultDecision(entry(), rule: careful).reason.contains("обережне"))

        XCTAssertTrue(DiskScanner.defaultDecision(entry(scope: .userFile), rule: safe).reason.contains("особисті"))
        XCTAssertTrue(DiskScanner.defaultDecision(entry(scope: .backup), rule: safe).reason.contains("резервна"))
        XCTAssertTrue(DiskScanner.defaultDecision(entry(scope: .application), rule: safe).reason.contains("програма"))

        let admin = try makeRule(paths: ["/Library/Caches"], extra: "\"requiresAdmin\":true")
        XCTAssertTrue(DiskScanner.defaultDecision(entry(), rule: admin).reason.contains("пароль"))
    }

    func testAgeThresholdReasonsMentionDays() throws {
        let rule = try makeRule(paths: ["~/a"], extra: "\"autoSelectOlderThanDays\":30")
        let fresh = DiskScanner.defaultDecision(entry(daysAgo: 5), rule: rule)
        XCTAssertFalse(fresh.selected)
        XCTAssertTrue(fresh.reason.contains("5 дн.") && fresh.reason.contains("30"), fresh.reason)
        let old = DiskScanner.defaultDecision(entry(daysAgo: 90), rule: rule)
        XCTAssertTrue(old.selected)
        XCTAssertTrue(old.reason.contains("90 дн."))
        XCTAssertFalse(DiskScanner.defaultDecision(entry(daysAgo: nil), rule: rule).selected)
    }

    func testBooleanHelperMatchesDecision() throws {
        let rule = try makeRule(paths: ["~/a"])
        XCTAssertEqual(DiskScanner.isSelectedByDefault(entry(), rule: rule), DiskScanner.defaultDecision(entry(), rule: rule).selected)
    }
}

final class ReportTransparencyTests: CleanerTestCase {
    private func entry(_ home: FakeHome, _ name: String, rule: String, bytes: Int64, scope: EntryScope = .home, locked: String? = nil) -> Entry {
        var entry = Entry(ruleID: rule, url: home.path("Documents/\(name)"), lockedReason: locked, scope: scope)
        entry.measurement = DiskUsage(bytes: bytes, fileCount: 1, lastModified: Date().addingTimeInterval(-3 * 86_400), hadErrors: false)
        return entry
    }

    private func render(_ home: FakeHome, results: [RuleResult], selected: Set<String>, manual: Set<String>) -> String {
        DiagnosticReport.render(DiagnosticInput(
            appVersion: "1", dryRun: true, macOSVersion: "26", architecture: "arm64", fullDiskAccess: true, disk: nil,
            projectRoots: [], fileSettings: nil, groups: [CleanupGroup(id: "g", title: "Група", symbol: "x")],
            results: results, selectedIDs: selected, manualIDs: manual, ruleBlocks: [:],
            blockReason: { entry, _ in entry.lockedReason }, apps: [], survey: [], home: home.url))
    }

    func testAutoManualRemovedAndBlockedAreAllDistinguished() throws {
        let home = try FakeHome()
        let cache = try makeRule(id: "cache", paths: ["~/a"])    // безпечне: вибирається саме
        let files = try makeRule(id: "files", paths: ["~/b"], extra: "\"moveToTrash\":true")
        let autoEntry = entry(home, "auto.bin", rule: "cache", bytes: 500_000_000)
        let removed = entry(home, "removed.bin", rule: "cache", bytes: 300_000_000)
        let blocked = entry(home, "busy.bin", rule: "cache", bytes: 200_000_000, locked: "Застосунок запущений")
        let manualOn = entry(home, "mine.psd", rule: "files", bytes: 100_000_000, scope: .userFile)
        let untouched = entry(home, "other.psd", rule: "files", bytes: 90_000_000, scope: .userFile)

        let text = render(
            home,
            results: [RuleResult(rule: cache, entries: [autoEntry, removed, blocked]), RuleResult(rule: files, entries: [manualOn, untouched])],
            selected: [autoEntry.id, manualOn.id], manual: [removed.id, manualOn.id])

        // Підсумок розрізняє походження вибору.
        XCTAssertTrue(text.contains("Вибрано АВТОМАТИЧНО (за замовчуванням): 1 елементів, 500 МБ"), text)
        XCTAssertTrue(text.contains("Додано ВРУЧНУ користувачем: 1 елементів, 100 МБ"))
        XCTAssertTrue(text.contains("Знято ВРУЧНУ (програма вибрала б сама): 1 елементів, 300 МБ"))
        XCTAssertTrue(text.contains("Не вибрано, бо лише вручну: 1 елементів, 90 МБ"))
        XCTAssertTrue(text.contains("особисті файли: лише вручну: 1 елементів"))
        XCTAssertTrue(text.contains("ЗАБЛОКОВАНО (зараз не можна вибрати): 1 елементів, 200 МБ"))
        XCTAssertTrue(text.contains("Застосунок запущений: 1 елементів, 200 МБ"))
        XCTAssertTrue(text.contains("РАЗОМ ВИБРАНО ЗАРАЗ: 2 елементів"))

        // Кожен рядок має свою позначку.
        XCTAssertTrue(text.contains("[✓ авто] 500 МБ") && text.contains("auto.bin"))
        XCTAssertTrue(text.contains("[✗ ЗНЯТО ВРУЧНУ] 300 МБ") && text.contains("removed.bin"))
        XCTAssertTrue(text.contains("[🔒] 200 МБ") && text.contains("busy.bin"))
        XCTAssertTrue(text.contains("[✓ ВРУЧНУ] 100 МБ") && text.contains("mine.psd"))
        XCTAssertTrue(text.contains("[  ] 90 МБ") && text.contains("other.psd"))
    }

    func testLegendAndRulePolicyAreExplained() throws {
        let home = try FakeHome()
        let files = try makeRule(id: "files", paths: ["~/b"], extra: "\"moveToTrash\":true")
        let installer = entry(home, "App.dmg", rule: "files", bytes: 50_000_000, scope: .userFile)
        let text = render(home, results: [RuleResult(rule: files, entries: [installer])], selected: [], manual: [])
        XCTAssertTrue(text.contains("[✓ авто]            вибрано програмою за замовчуванням"))
        XCTAssertTrue(text.contains("[✓ ВРУЧНУ]"))
        XCTAssertTrue(text.contains("автовибір: ні (особисті файли: лише вручну)"), text)
    }

    func testAgeBasedRuleShowsPerEntryReason() throws {
        let home = try FakeHome()
        let rule = try makeRule(id: "proj", paths: ["~/p"], extra: "\"autoSelectOlderThanDays\":30")
        let fresh = entry(home, "fresh", rule: "proj", bytes: 70_000_000)  // 3 дні тому
        let text = render(home, results: [RuleResult(rule: rule, entries: [fresh])], selected: [], manual: [])
        XCTAssertTrue(text.contains("автовибір: лише те, що не змінювалось 30+ днів"))
        XCTAssertTrue(text.contains("активність 3 дн. тому (потрібно від 30)"), text)
    }

    func testAllEntriesUpToTheCapAreListedNotJustSelected() throws {
        let home = try FakeHome()
        let rule = try makeRule(id: "r", paths: ["~/a"], extra: "\"moveToTrash\":true")
        let entries = (0..<80).map { entry(home, "f\($0).bin", rule: "r", bytes: Int64(2_000_000 + $0), scope: .userFile) }
        let text = render(home, results: [RuleResult(rule: rule, entries: entries)], selected: [], manual: [])
        XCTAssertEqual(text.components(separatedBy: "~/Documents/f").count - 1, 80, "усе знайдене видно, а не лише вибране")
    }
}

final class IllustratorSettingsTests: CleanerTestCase {
    private func setup() throws -> (FakeHome, URL) {
        let home = try FakeHome()
        let apps = home.path("Apps")
        try makeApp(home, at: "Apps/Adobe Illustrator 2025/Adobe Illustrator.app", bundleID: "com.adobe.illustrator", name: "Adobe Illustrator", version: "29.8.7")
        try makeApp(home, at: "Apps/Adobe Illustrator 2026/Adobe Illustrator.app", bundleID: "com.adobe.illustrator", name: "Adobe Illustrator", version: "30.3.0")
        for n in [27, 28, 29, 30] { try home.makeFile("Library/Preferences/Adobe Illustrator \(n) Settings/en_US/prefs.bin", bytes: 60_000) }
        try home.makeFile("Library/Preferences/Adobe Photoshop (Beta) Settings/x", bytes: 5_000)
        try home.makeFile("Library/Preferences/com.apple.finder.plist", bytes: 2_000)
        return (home, apps)
    }

    func testInstalledMajorsComeFromRealApps() throws {
        let (home, apps) = try setup()
        defer { withExtendedLifetime(home) {} }
        XCTAssertEqual(AdobeSettings.installedIllustratorMajors(roots: [apps]), [29, 30])
    }

    func testOnlySettingsOfMissingVersionsAreCandidates() throws {
        let (home, apps) = try setup()
        defer { withExtendedLifetime(home) {} }
        let result = AdobeSettings.discover(home: home.url, applicationRoots: [apps])
        XCTAssertEqual(result.entries.map(\.name), [
            "Adobe Illustrator 27 Settings", "Adobe Illustrator 28 Settings",
            "Adobe Illustrator 29 Settings", "Adobe Illustrator 30 Settings"])
        XCTAssertEqual(result.entries.filter { $0.lockedReason == nil }.map(\.name),
                       ["Adobe Illustrator 27 Settings", "Adobe Illustrator 28 Settings"])
        XCTAssertTrue(result.entries.filter { $0.lockedReason != nil }.allSatisfy(\.informational))
        XCTAssertEqual(result.rule.moveToTrash, true)
    }

    func testGuardAllowsOnlyThatExactFolderInPreferences() throws {
        let home = try FakeHome()
        let guardian = PathGuard(home: home.url)
        XCTAssertNoThrow(try guardian.validate(home.path("Library/Preferences/Adobe Illustrator 27 Settings")))
        XCTAssertThrowsError(try guardian.validate(home.path("Library/Preferences/Adobe Illustrator 27 Settings/en_US")), "вміст не чіпаємо")
        XCTAssertThrowsError(try guardian.validate(home.path("Library/Preferences/Adobe Illustrator Settings")))
        XCTAssertThrowsError(try guardian.validate(home.path("Library/Preferences/com.apple.finder.plist")))
        XCTAssertThrowsError(try guardian.validate(home.path("Library/Preferences/Adobe Photoshop 2026 Settings")))
        XCTAssertThrowsError(try guardian.validate(home.path("Library/Preferences")))
    }

    func testEngineTrashesMissingVersionsAndKeepsInstalledOnes() throws {
        let (home, apps) = try setup()
        defer { withExtendedLifetime(home) {} }
        var entries = AdobeSettings.discover(home: home.url, applicationRoots: [apps]).entries
        for index in entries.indices { entries[index].measurement = DiskSize.measure(entries[index].url) }
        let trasher = FakeTrasher(directory: home.path("tr"))
        let report = makeEngine(home, applicationRoots: [apps], trasher: trasher).clean(
            entries: entries, rules: [AdobeSettings.rule], dryRun: false)
        XCTAssertFalse(home.exists("Library/Preferences/Adobe Illustrator 27 Settings"))
        XCTAssertFalse(home.exists("Library/Preferences/Adobe Illustrator 28 Settings"))
        XCTAssertTrue(home.exists("Library/Preferences/Adobe Illustrator 29 Settings"), "встановлена версія лишається")
        XCTAssertTrue(home.exists("Library/Preferences/Adobe Illustrator 30 Settings"))
        XCTAssertEqual(report.skipped.count, 2)
        XCTAssertGreaterThan(report.trashedBytes, 0)
    }
}

final class DeepDrillDownTests: CleanerTestCase {
    func testSecondLevelOfBigFoldersIsListed() throws {
        let home = try FakeHome()
        try home.makeFile("Lib/Preferences/Settings28/cache/blob.bin", bytes: 400_000)
        try home.makeFile("Lib/Preferences/Settings28/prefs.plist", bytes: 3_000)
        try home.makeFile("Lib/Preferences/small/x.bin", bytes: 3_000)
        let section = try XCTUnwrap(DiskSurvey.run(
            home: home.url, directories: [SurveyDirectory(title: "Lib", url: home.path("Lib"))], drillThreshold: 100_000).first)
        let preferences = try XCTUnwrap(section.items.first { $0.name == "Preferences" })
        let settings = try XCTUnwrap(preferences.children.first { $0.name == "Settings28" })
        XCTAssertEqual(settings.children.first?.name, "cache", "видно, що саме всередині великої теки")
    }

    func testReportIndentsNestedChildren() throws {
        let home = try FakeHome()
        let inner = SurveyItem(name: "cache", bytes: 4_000_000_000, lastModified: nil)
        let middle = SurveyItem(name: "Adobe Illustrator 28 Settings", bytes: 4_500_000_000, lastModified: nil, children: [inner])
        let top = SurveyItem(name: "Preferences", bytes: 21_000_000_000, lastModified: Date(), children: [middle])
        let section = SurveySection(title: "~/Library", path: "/l", items: [top], totalCount: 1, restBytes: 0, error: nil)
        let text = DiagnosticReport.render(DiagnosticInput(
            appVersion: "1", dryRun: true, macOSVersion: "26", architecture: "arm64", fullDiskAccess: true, disk: nil,
            projectRoots: [], fileSettings: nil, groups: [], results: [], selectedIDs: [], ruleBlocks: [:],
            blockReason: { _, _ in nil }, apps: [], survey: [section], home: home.url))
        XCTAssertTrue(text.contains("      └ 4,5 ГБ  Adobe Illustrator 28 Settings"), text)
        XCTAssertTrue(text.contains("          └ 4 ГБ  cache"), text)
    }
}

/// Наскрізна перевірка: від скану до «вибрано за замовчуванням». Особисте не може вибратись саме.
final class EndToEndDefaultSelectionTests: CleanerTestCase {
    func testNothingPersonalIsSelectedAutomaticallyAfterAFullScan() async throws {
        let home = try FakeHome()
        // Інсталятори, великі файли, дублікати, бекап iPhone, програма, кеш Chrome-подібного вигляду.
        try home.makeFile("Downloads/Setup.dmg", bytes: 200_000)
        try home.makeFile("Downloads/video.mov", bytes: 400_000)
        try home.makeFile("Documents/work.psd", bytes: 500_000)
        let content = Data(repeating: 7, count: 300_000)
        for path in ["Downloads/dup1.bin", "Documents/dup2.bin"] {
            try FileManager.default.createDirectory(at: home.path(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: home.path(path))
        }
        try makeApp(home, at: "Apps/Foo.app", bundleID: "com.vendor.foo", name: "Foo")
        try home.makeFile("Library/Application Support/MobileSync/Backup/00008110-001A2B3C4D5E6F78/blob.bin", bytes: 50_000)
        try home.makeFile("Library/Caches/SomeApp/data.bin", bytes: 40_000)

        let settings = FileScanSettings(
            roots: ["Downloads", "Documents"].map { home.path($0) }, minLargeBytes: 150_000, minDuplicateBytes: 100_000, minInstallerBytes: 50_000)
        let cacheRule = try makeRule(id: "cache", paths: ["~/Library/Caches"])
        let scanner = DiskScanner(ruleSet: makeRuleSet([cacheRule]), home: home.url, fileSettings: settings, applicationRoots: [home.path("Apps")])

        var results: [String: RuleResult] = [:]
        var measured: [String: DiskUsage] = [:]
        for await event in scanner.scan() {
            switch event {
            case .discovered(let found): results = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
            case .appended(let found): for result in found { results[result.id] = result }
            case .measured(let id, let usage): measured[id] = usage
            default: break
            }
        }

        var personal = 0, autoSelected: [String] = []
        for result in results.values {
            for var entry in result.entries {
                entry.measurement = measured[entry.id]
                if [EntryScope.userFile, .backup, .application].contains(entry.scope) { personal += 1 }
                if DiskScanner.isSelectedByDefault(entry, rule: result.rule) { autoSelected.append("\(result.rule.id): \(entry.name)") }
            }
        }
        XCTAssertGreaterThanOrEqual(personal, 5, "сканер справді знайшов особисте: інсталятор, файли, дублікат, бекап, програму")
        XCTAssertEqual(autoSelected, ["cache: SomeApp"], "автоматично вибирається лише безпечний кеш")
    }
}

final class SelectionClassificationTests: CleanerTestCase {
    private func entry(_ home: FakeHome, _ name: String, rule: String, scope: EntryScope = .home) -> Entry {
        var entry = Entry(ruleID: rule, url: home.path("Documents/\(name)"), scope: scope)
        entry.measurement = DiskUsage(bytes: 100_000_000, fileCount: 1, lastModified: Date().addingTimeInterval(-86_400), hadErrors: false)
        return entry
    }

    private func render(_ home: FakeHome, _ results: [RuleResult], selected: Set<String>, manual: Set<String>) -> String {
        DiagnosticReport.render(DiagnosticInput(
            appVersion: "1", dryRun: true, macOSVersion: "26", architecture: "arm64", fullDiskAccess: true, disk: nil,
            projectRoots: [], fileSettings: nil, groups: [CleanupGroup(id: "g", title: "Г", symbol: "x")],
            results: results, selectedIDs: selected, manualIDs: manual, ruleBlocks: [:],
            blockReason: { _, _ in nil }, apps: [], survey: [], home: home.url))
    }

    private func lines(_ text: String, marker: String) -> [String] {
        text.components(separatedBy: "\n").filter { $0.hasPrefix("  \(marker) ") && $0.dropFirst(marker.count + 3).first?.isNumber == true }
    }

    func testClickingThereAndBackIsNotCountedAsManual() throws {
        let home = try FakeHome()
        let cache = try makeRule(id: "cache", paths: ["~/a"])
        let e = entry(home, "cache.bin", rule: "cache")
        // Користувач вимкнув і знову ввімкнув: id у «ручних», але стан як за замовчуванням.
        let text = render(home, [RuleResult(rule: cache, entries: [e])], selected: [e.id], manual: [e.id])
        XCTAssertEqual(lines(text, marker: "[✓ авто]").count, 1)
        XCTAssertEqual(lines(text, marker: "[✓ ВРУЧНУ]").count, 0)
        XCTAssertTrue(text.contains("Додано ВРУЧНУ користувачем: 0 елементів"))
        XCTAssertTrue(text.contains("Вибрано АВТОМАТИЧНО (за замовчуванням): 1 елементів"))
    }

    func testSelectionWithoutAnyReasonIsFlaggedAsProgramError() throws {
        let home = try FakeHome()
        let files = try makeRule(id: "files", paths: ["~/b"], extra: "\"moveToTrash\":true")
        let sneaky = entry(home, "Setup.dmg", rule: "files", scope: .userFile)   // особисте: автовибору немає, кліку теж
        let text = render(home, [RuleResult(rule: files, entries: [sneaky])], selected: [sneaky.id], manual: [])
        XCTAssertEqual(lines(text, marker: "[✓ ???]").count, 1, text)
        XCTAssertTrue(text.contains("⚠︎ Вибрано з НЕВІДОМОЇ причини"))
        XCTAssertTrue(text.contains("Це помилка програми"))
        XCTAssertTrue(text.contains("РАЗОМ ВИБРАНО ЗАРАЗ: 1 елементів"), "підозріле теж враховано в підсумку")
    }

    func testUnselectedStatesAreDistinguished() throws {
        let home = try FakeHome()
        let cache = try makeRule(id: "cache", paths: ["~/a"])
        let removed = entry(home, "removed.bin", rule: "cache")
        let untouched = entry(home, "untouched.bin", rule: "cache")
        let text = render(home, [RuleResult(rule: cache, entries: [removed, untouched])], selected: [], manual: [removed.id])
        XCTAssertEqual(lines(text, marker: "[✗ ЗНЯТО ВРУЧНУ]").count, 1)
        XCTAssertEqual(lines(text, marker: "[  ]").count, 1)
        XCTAssertFalse(text.contains("з НЕВІДОМОЇ причини"), "відсутність вибору не є помилкою")
    }

    func testManualPersonalSelectionIsRecognised() throws {
        let home = try FakeHome()
        let files = try makeRule(id: "files", paths: ["~/b"], extra: "\"moveToTrash\":true")
        let mine = entry(home, "mine.psd", rule: "files", scope: .userFile)
        let text = render(home, [RuleResult(rule: files, entries: [mine])], selected: [mine.id], manual: [mine.id])
        XCTAssertEqual(lines(text, marker: "[✓ ВРУЧНУ]").count, 1)
        XCTAssertTrue(text.contains("Додано ВРУЧНУ користувачем: 1 елементів"))
        XCTAssertFalse(text.contains("з НЕВІДОМОЇ причини"))
    }
}
