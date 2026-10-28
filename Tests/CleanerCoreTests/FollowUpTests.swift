import XCTest
@testable import CleanerCore

final class BulkSelectionPolicyTests: XCTestCase {
    func testPersonalDataRulesCannotBeBulkSelected() throws {
        for category in FileCategory.allCases { XCTAssertFalse(category.rule.bulkSelectable, category.rule.id) }
        XCTAssertFalse(BackupProvider.rule.bulkSelectable)
        XCTAssertFalse(AppProvider.rule.bulkSelectable)
        XCTAssertFalse(AdobeVersions.rule.bulkSelectable)
    }

    func testInstallersAndDuplicatesAndCachesRemainBulkSelectable() throws {
        XCTAssertTrue(FileScanner.installersRule.bulkSelectable)
        XCTAssertTrue(FileScanner.duplicatesRule.bulkSelectable)
        for rule in try RuleLoader.builtin().rules where rule.risk == .safe {
            XCTAssertTrue(rule.bulkSelectable, rule.id)
        }
    }

    func testBulkSelectableDefaultsToTrueInJSON() throws {
        XCTAssertTrue(try makeRule(paths: ["~/a"]).bulkSelectable)
        XCTAssertFalse(try makeRule(paths: ["~/a"], extra: "\"bulkSelectable\":false").bulkSelectable)
    }

    func testNothingPersonalIsRecommended() {
        // «Рекомендоване» = вибране за замовчуванням, а воно ніколи не охоплює особисте.
        let rule = FileScanner.duplicatesRule
        for scope in [EntryScope.userFile, .backup, .application] {
            var entry = Entry(ruleID: rule.id, url: URL(fileURLWithPath: "/tmp/x"), scope: scope)
            entry.measurement = DiskUsage(bytes: 1, fileCount: 1, lastModified: Date(timeIntervalSince1970: 0), hadErrors: false)
            XCTAssertFalse(DiskScanner.isSelectedByDefault(entry, rule: rule))
        }
    }
}

final class OptionalAppleAppsTests: XCTestCase {
    func testOptionalAppleAppsAreOfferedButSystemOnesAreNot() throws {
        let home = try FakeHome()
        let apps = home.path("Apps")
        try makeApp(home, at: "Apps/iMovie.app", bundleID: "com.apple.iMovieApp", name: "iMovie")
        try makeApp(home, at: "Apps/Pages.app", bundleID: "com.apple.iWork.Pages", name: "Pages")
        try makeApp(home, at: "Apps/Safari.app", bundleID: "com.apple.Safari", name: "Safari")
        try makeApp(home, at: "Apps/Finder.app", bundleID: "com.apple.finder", name: "Finder")

        let names = AppProvider.discover(home: home.url, roots: [apps]).entries.map(\.name)
        XCTAssertEqual(Set(names), ["iMovie", "Pages"])

        let policy = SafetyPolicy(home: home.url, applicationRoots: [apps])
        let imovie = try XCTUnwrap(AppProvider.discover(home: home.url, roots: [apps]).entries.first { $0.name == "iMovie" })
        XCTAssertNoThrow(try policy.validate(imovie))
        let safari = Entry(ruleID: AppProvider.rule.id, url: apps.appendingPathComponent("Safari.app"), scope: .application,
                           action: .trashPaths, ownerTokens: ["com.apple.Safari"])
        XCTAssertThrowsError(try policy.validate(safari))
    }
}

final class AdobeVersionsTests: XCTestCase {
    func testParsesNames() {
        XCTAssertEqual(AdobeVersions.parse("Adobe Photoshop 2025")?.product, "Adobe Photoshop")
        XCTAssertEqual(AdobeVersions.parse("Adobe Photoshop 2025")?.year, 2025)
        XCTAssertEqual(AdobeVersions.parse("Adobe After Effects 2024")?.year, 2024)
        XCTAssertNil(AdobeVersions.parse("Adobe Photoshop (Beta)"))
        XCTAssertNil(AdobeVersions.parse("Microsoft Word 2024"))
    }

    private func setup() throws -> (FakeHome, URL) {
        let home = try FakeHome()
        let apps = home.path("Apps")
        for folder in ["Adobe Photoshop 2025", "Adobe Photoshop 2026", "Adobe Photoshop (Beta)", "Adobe Illustrator 2026", "Adobe After Effects 2024"] {
            try home.makeFile("Apps/\(folder)/Contents/data.bin", bytes: 60_000)
        }
        try home.makeFile("Apps/Adobe Notes.txt", bytes: 100)
        return (home, apps)
    }

    func testOnlyOlderAndBetaVersionsAreListed() throws {
        let (home, apps) = try setup()
        defer { withExtendedLifetime(home) {} }
        let result = AdobeVersions.discover(roots: [apps])
        XCTAssertEqual(result.entries.map(\.name), ["Adobe Photoshop (Beta)", "Adobe Photoshop 2025"])
        let old = try XCTUnwrap(result.entries.first { $0.name == "Adobe Photoshop 2025" })
        XCTAssertEqual(old.subtitle, "є новіша версія: 2026")
        XCTAssertTrue(old.informational)
        XCTAssertNotNil(old.lockedReason)
        XCTAssertTrue(try XCTUnwrap(old.lockedReason).contains("Creative Cloud"))
    }

    func testEngineNeverTouchesAdobeFoldersEvenIfForced() throws {
        let (home, apps) = try setup()
        var entry = try XCTUnwrap(AdobeVersions.discover(roots: [apps]).entries.first { $0.name == "Adobe Photoshop 2025" })
        entry.measurement = DiskSize.measure(entry.url)
        var unlocked = entry
        unlocked.lockedReason = nil   // навіть якщо хтось зніме блокування, охоронець не дозволить
        let report = makeEngine(home, applicationRoots: [apps]).clean(
            entries: [entry, unlocked], rules: [AdobeVersions.rule], dryRun: false)
        XCTAssertEqual(report.skipped.count, 2)
        XCTAssertTrue(home.exists("Apps/Adobe Photoshop 2025"))
    }

    func testScannerMeasuresInformationalEntries() async throws {
        let (home, apps) = try setup()
        defer { withExtendedLifetime(home) {} }
        let scanner = DiskScanner(ruleSet: makeRuleSet([]), home: home.url, applicationRoots: [apps])
        var measured: [String: DiskUsage] = [:]
        var adobeIDs = Set<String>()
        for await event in scanner.scan() {
            switch event {
            case .appended(let found): adobeIDs.formUnion(found.filter { $0.id == AdobeVersions.rule.id }.flatMap(\.entries).map(\.id))
            case .measured(let id, let usage): measured[id] = usage
            default: break
            }
        }
        XCTAssertEqual(adobeIDs.count, 2)
        for id in adobeIDs { XCTAssertGreaterThan(measured[id]?.bytes ?? 0, 0, id) }
    }
}

final class TelegramRuleTests: XCTestCase {
    func testOnlyMediaIsTargetedAndRunningTelegramBlocks() throws {
        let home = try FakeHome()
        let base = "Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram"
        try home.makeFile("\(base)/appstore/account-111/postbox/media/photo.jpg", bytes: 50_000)
        try home.makeFile("\(base)/appstore/account-111/postbox/db/db_sqlite", bytes: 50_000)
        try home.makeFile("\(base)/stable/account-222/postbox/media/video.mp4", bytes: 70_000)
        let rule = try XCTUnwrap(RuleLoader.builtin().rules.first { $0.id == "apps.telegramMedia" })
        XCTAssertEqual(rule.risk, .careful)

        let result = DiskScanner(ruleSet: makeRuleSet([rule]), home: home.url).discover()[0]
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertTrue(result.entries.allSatisfy { $0.url.lastPathComponent == "media" })

        let running = RunningSnapshot(bundleIDs: ["ru.keepcoder.Telegram"], appNames: ["telegram"])
        XCTAssertNotNil(RunningProbe.blockReason(for: rule, snapshot: running))
        XCTAssertNil(RunningProbe.blockReason(for: rule, snapshot: RunningSnapshot()))

        var entries = result.entries
        for index in entries.indices { entries[index].measurement = DiskSize.measure(entries[index].url) }
        // У тесті Telegram, найімовірніше, запущений: перевіряємо лише, що саме видаляється, без блокування.
        let unblocked = CleanupRule(id: rule.id, group: rule.group, title: rule.title, detail: rule.detail, risk: rule.risk, paths: rule.paths, granularity: rule.granularity)
        let report = makeEngine(home).clean(entries: entries, rules: [unblocked], dryRun: false)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(home.exists("\(base)/appstore/account-111/postbox/media"))
        XCTAssertTrue(home.exists("\(base)/appstore/account-111/postbox/db/db_sqlite"), "база чатів лишається")
    }
}

final class SurveyDrillDownTests: XCTestCase {
    func testBigFoldersAreExpandedOneLevel() throws {
        let home = try FakeHome()
        try home.makeFile("Lib/Preferences/huge/a.bin", bytes: 300_000)
        try home.makeFile("Lib/Preferences/huge/b.bin", bytes: 150_000)
        try home.makeFile("Lib/Preferences/other.plist", bytes: 5_000)
        try home.makeFile("Lib/Small/x.bin", bytes: 5_000)
        let section = try XCTUnwrap(DiskSurvey.run(
            home: home.url, directories: [SurveyDirectory(title: "Lib", url: home.path("Lib"))], drillThreshold: 200_000).first)

        let big = try XCTUnwrap(section.items.first { $0.name == "Preferences" })
        XCTAssertEqual(big.children.map(\.name), ["huge", "other.plist"])
        XCTAssertTrue(try XCTUnwrap(section.items.first { $0.name == "Small" }).children.isEmpty)
    }

    func testDrillDownCanBeDisabledAndLimitsChildren() throws {
        let home = try FakeHome()
        for i in 0..<20 { try home.makeFile("Lib/Big/item\(i)/a.bin", bytes: 20_000) }
        let off = try XCTUnwrap(DiskSurvey.run(
            home: home.url, directories: [SurveyDirectory(title: "Lib", url: home.path("Lib"))], drillThreshold: 0).first)
        XCTAssertTrue(off.items[0].children.isEmpty)

        let on = try XCTUnwrap(DiskSurvey.run(
            home: home.url, directories: [SurveyDirectory(title: "Lib", url: home.path("Lib"))], drillThreshold: 100_000).first)
        XCTAssertEqual(on.items[0].children.count, DiskSurvey.drillChildrenPerItem)
    }

    func testReportRendersChildren() throws {
        let home = try FakeHome()
        let child = SurveyItem(name: "adobe-cache", bytes: 20_000_000_000, lastModified: nil)
        let survey = [SurveySection(
            title: "~/Library (решта)", path: "/l",
            items: [SurveyItem(name: "Preferences", bytes: 21_000_000_000, lastModified: Date(), children: [child])],
            totalCount: 1, restBytes: 0, error: nil)]
        let input = DiagnosticInput(
            appVersion: "1", dryRun: true, macOSVersion: "26", architecture: "arm64", fullDiskAccess: true, disk: nil,
            projectRoots: [], fileSettings: nil, groups: [], results: [], selectedIDs: [], ruleBlocks: [:],
            blockReason: { _, _ in nil }, apps: [], survey: survey, home: home.url)
        let text = DiagnosticReport.render(input)
        XCTAssertTrue(text.contains("Preferences"))
        XCTAssertTrue(text.contains("└ 20 GB  adobe-cache"), text)
    }
}

/// Регресії, знайдені за реальним логом з чужого Mac.
final class LogDrivenRegressionTests: XCTestCase {
    func testBundlePatternsAreCaseInsensitive() throws {
        // Реальний bundle ID Illustrator — з малої літери, а шаблон правила міг бути з великої.
        let snapshot = RunningSnapshot(bundleIDs: ["com.adobe.illustrator"], appNames: [])
        let rule = try makeRule(paths: ["~/x"], extra: "\"blockedByApps\":[\"com.adobe.Illustrator*\"]")
        XCTAssertNotNil(RunningProbe.blockReason(for: rule, snapshot: snapshot))
        XCTAssertTrue(snapshot.isRunning(bundlePattern: "COM.ADOBE.ILLUSTRATOR"))
        XCTAssertFalse(snapshot.isRunning(bundlePattern: "com.adobe.photoshop*"))
    }

    func testBuiltinAdobeCacheRuleIsBlockedByRunningCreativeApps() throws {
        let rule = try XCTUnwrap(RuleLoader.builtin().rules.first { $0.id == "design.adobeCaches" })
        for bundleID in ["com.adobe.illustrator", "com.adobe.Photoshop", "com.adobe.InDesign", "com.adobe.bridge", "com.adobe.AfterEffects"] {
            XCTAssertNotNil(
                RunningProbe.blockReason(for: rule, snapshot: RunningSnapshot(bundleIDs: [bundleID], appNames: [])), bundleID)
        }
        // Фонові служби Creative Cloud не мають блокувати чищення назавжди.
        let background = RunningSnapshot(bundleIDs: ["com.adobe.acc.AdobeCreativeCloud", "com.adobe.ccd.helper"], appNames: [])
        XCTAssertNil(RunningProbe.blockReason(for: rule, snapshot: background))
    }

    func testIllustratorAndCepCachesBelongToAdobeRuleNotTheCatchAll() throws {
        let home = try FakeHome()
        try home.makeFile("Library/Caches/AI_30_3/cache.bin", bytes: 20_000)
        try home.makeFile("Library/Caches/CSXS/x.bin", bytes: 20_000)
        try home.makeFile("Library/Caches/SomeOtherApp/x.bin", bytes: 20_000)
        let builtin = try RuleLoader.builtin()
        let rules = builtin.rules.filter { ["design.adobeCaches", "apps.caches"].contains($0.id) }
        let results = DiskScanner(ruleSet: makeRuleSet(rules), home: home.url).discover()
        let adobe = Set(results.first { $0.id == "design.adobeCaches" }?.entries.map(\.name) ?? [])
        let rest = Set(results.first { $0.id == "apps.caches" }?.entries.map(\.name) ?? [])
        XCTAssertEqual(adobe, ["AI_30_3", "CSXS"], "їхній захист від запущеного Illustrator має працювати")
        XCTAssertEqual(rest, ["SomeOtherApp"])
    }

    func testSurveySkipsAppBundleInternals() throws {
        let home = try FakeHome()
        try home.makeFile("Lib/Adobe Tool/Big.app/Contents/MacOS/bin", bytes: 400_000)
        try home.makeFile("Lib/Adobe Tool/Plug-ins/p.bin", bytes: 300_000)
        try home.makeFile("Lib/Standalone.app/Contents/data", bytes: 500_000)
        let section = try XCTUnwrap(DiskSurvey.run(
            home: home.url, directories: [SurveyDirectory(title: "Lib", url: home.path("Lib"))], drillThreshold: 100_000).first)
        let tool = try XCTUnwrap(section.items.first { $0.name == "Adobe Tool" })
        let app = try XCTUnwrap(tool.children.first { $0.name == "Big.app" })
        XCTAssertTrue(app.children.isEmpty, "усередину .app не заглядаємо")
        XCTAssertTrue(try XCTUnwrap(section.items.first { $0.name == "Standalone.app" }).children.isEmpty)
    }

    func testSurveyGoesThreeLevelsDeep() throws {
        let home = try FakeHome()
        try home.makeFile("Lib/Prefs/Settings28/uk_UA/ml-cache/blob.bin", bytes: 500_000)
        let section = try XCTUnwrap(DiskSurvey.run(
            home: home.url, directories: [SurveyDirectory(title: "Lib", url: home.path("Lib"))], drillThreshold: 100_000).first)
        let prefs = try XCTUnwrap(section.items.first)
        let locale = try XCTUnwrap(prefs.children.first?.children.first)
        XCTAssertEqual(locale.name, "uk_UA")
        XCTAssertEqual(locale.children.first?.name, "ml-cache", "видно, що саме важить у локалі")
    }
}

final class BackgroundHelperTests: XCTestCase {
    func testBackgroundAgentDoesNotBlockTheAppsOwnCaches() {
        // Реальний випадок: працює лише фоновий figma_agent, сам Figma закрито.
        let snapshot = RunningSnapshot(
            bundleIDs: ["com.figma.agent"], appNames: ["figma_agent"], regularAppNames: [])
        XCTAssertFalse(snapshot.ownsCache(named: "Figma"), "кеш Figma не належить фоновому агентові")
        XCTAssertTrue(snapshot.ownsCache(named: "com.figma.agent"), "власний кеш агента лишається захищеним")
        XCTAssertTrue(snapshot.ownsCache(named: "figma_agent"))
    }

    func testRegularAppStillBlocksByPartialName() {
        let snapshot = RunningSnapshot(bundleIDs: ["com.google.Chrome"], appNames: ["google chrome"], regularAppNames: ["google chrome"])
        XCTAssertTrue(snapshot.ownsCache(named: "Google"))
    }

    func testRegularNamesDefaultToAllNamesForBackwardCompatibility() {
        let snapshot = RunningSnapshot(bundleIDs: [], appNames: ["telegram"])
        XCTAssertTrue(snapshot.ownsCache(named: "Telegram"))
        XCTAssertEqual(snapshot.regularAppNames, ["telegram"])
    }
}

final class SurveyPinnedItemsTests: XCTestCase {
    func testNotesAndIncompleteItemsSurviveTheTopCut() throws {
        let home = try FakeHome()
        // Більше елементів, ніж вміщає топ; «хмарна» тека має нульовий розмір і за розміром випала б.
        for i in 0..<(DiskSurvey.topPerSection + 10) { try home.makeFile("Lib/item\(i)/a.bin", bytes: 6_000) }
        try home.makeFile("Lib/Mobile Documents/x.bin", bytes: 6_000)
        let cloud = home.path("Lib/Mobile Documents").path
        let directory = SurveyDirectory(title: "Lib", url: home.path("Lib"), unmeasured: [cloud: "iCloud Drive: вміст не міряю"])
        let section = try XCTUnwrap(DiskSurvey.run(home: home.url, directories: [directory]).first)

        let pinned = try XCTUnwrap(section.items.first { $0.name == "Mobile Documents" })
        XCTAssertEqual(pinned.note, "iCloud Drive: вміст не міряю")
        XCTAssertGreaterThan(section.totalCount, DiskSurvey.topPerSection, "елементів більше за топ")
        XCTAssertEqual(section.items.count, DiskSurvey.topPerSection + 1, "топ плюс закріплений")
    }

    func testPinnedItemsAppearInTheReport() throws {
        let home = try FakeHome()
        for i in 0..<(DiskSurvey.topPerSection + 5) { try home.makeFile("Lib/item\(i)/a.bin", bytes: 6_000) }
        try home.makeFile("Lib/CloudStorage/x.bin", bytes: 6_000)
        let directory = SurveyDirectory(
            title: "Lib", url: home.path("Lib"), unmeasured: [home.path("Lib/CloudStorage").path: "хмарні сховища: вміст не міряю"])
        let survey = DiskSurvey.run(home: home.url, directories: [directory])
        let text = DiagnosticReport.render(DiagnosticInput(
            appVersion: "1", dryRun: true, macOSVersion: "26", architecture: "arm64", fullDiskAccess: true, disk: nil,
            projectRoots: [], fileSettings: nil, groups: [], results: [], selectedIDs: [], ruleBlocks: [:],
            blockReason: { _, _ in nil }, apps: [], survey: survey, home: home.url))
        XCTAssertTrue(text.contains("CloudStorage") && text.contains("хмарні сховища: вміст не міряю"), text)
    }
}

final class UserLogsRuleTests: XCTestCase {
    func testSystemManagedDiagnosticReportsFolderIsNeverOffered() throws {
        let home = try FakeHome()
        try home.makeFile("Library/Logs/SomeApp/app.log", bytes: 20_000)
        try home.makeFile("Library/Logs/DiagnosticReports/SFA-x.diag", bytes: 20_000)
        let rule = try XCTUnwrap(RuleLoader.builtin().rules.first { $0.id == "system.logs" })
        let entries = DiskScanner(ruleSet: makeRuleSet([rule]), home: home.url).discover()[0].entries
        XCTAssertEqual(entries.map(\.name), ["SomeApp"], "теку DiagnosticReports веде macOS, її не чіпаємо")
    }
}
