import XCTest
@testable import CleanerCore

/// Регресійні тести за результатами незалежного аудиту безпеки.
final class PathGuardHardeningTests: CleanerTestCase {
    func testDeniedAndProtectedPathsAreCaseInsensitive() throws {
        // Файлова система macOS не розрізняє регістр: `~/documents` — це `~/Documents`.
        let home = try FakeHome()
        let guardian = PathGuard(home: home.url)
        for relative in [
            "documents/Projects/x", "DOCUMENTS/Projects/x", "library/mail/V10", "Library/caches", "LIBRARY/Application support",
            "library/keychains/login.keychain-db", ".SSH/id_rsa", "LIBRARY/preferences/x.plist", "library/mobile documents/x",
        ] {
            XCTAssertThrowsError(try guardian.validate(home.path(relative)), relative)
        }
        // Звичайні дозволені шляхи й виняток для Illustrator працюють як раніше.
        XCTAssertNoThrow(try guardian.validate(home.path("Library/Caches/com.foo/Cache")))
        XCTAssertNoThrow(try guardian.validate(home.path("Library/Preferences/Adobe Illustrator 27 Settings")))
        // Виняток чутливий до регістру: інший регістр лишається забороненим.
        XCTAssertThrowsError(try guardian.validate(home.path("library/preferences/adobe illustrator 27 settings")))
    }

    func testSymlinkIntoAProtectedFolderDoesNotLaunderThePath() throws {
        // `Library/Caches/evil -> ~/Documents/Work`: шлях `evil/Cache` лежить у Caches, а насправді в Documents.
        let home = try FakeHome()
        try home.makeFile("Documents/Work/Cache/file.bin")
        try FileManager.default.createDirectory(at: home.path("Library/Caches"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.path("Library/Caches/evil"), withDestinationURL: home.path("Documents/Work"))
        try FileManager.default.createDirectory(at: home.path("Library/Caches/real/Cache"), withIntermediateDirectories: true)

        let guardian = PathGuard(home: home.url)
        XCTAssertThrowsError(try guardian.validate(home.path("Library/Caches/evil/Cache")))
        XCTAssertNoThrow(try guardian.validate(home.path("Library/Caches/real/Cache")))
        // Сам symlink видаляється як посилання, тож його можна прибрати.
        XCTAssertNoThrow(try guardian.validate(home.path("Library/Caches/evil")))
    }

    func testProjectRootsAreCaseInsensitiveAboutLibraryAndApplications() throws {
        let home = try FakeHome()
        XCTAssertFalse(ArtifactGuard.isValidRoot(home.path("library/Projects"), home: home.url))
        XCTAssertFalse(ArtifactGuard.isValidRoot(home.path("APPLICATIONS/x"), home: home.url))
        XCTAssertTrue(ArtifactGuard.isValidRoot(home.path("Developer/x"), home: home.url))
    }
}

final class CustomRuleTrustTests: CleanerTestCase {
    private func writeUserRules(_ home: FakeHome, _ json: String) throws {
        let url = RuleLoader.userRulesURL(home: home.url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    func testUserRulesAreMarkedCustomAndCannotAskForAdminRights() throws {
        let home = try FakeHome()
        try writeUserRules(home, """
        {"groups": [], "rules": [
          {"id": "mine.x", "group": "g", "title": "X", "detail": "d", "risk": "safe", "paths": ["~/Library/Caches/Foo"], "requiresAdmin": true},
          {"id": "xcode.derivedData", "group": "xcode", "title": "Harmless title", "detail": "d", "risk": "safe", "paths": ["~/Library/Application Support/*"]}
        ]}
        """)
        let rules = try RuleLoader.load(home: home.url, language: .en)
        let mine = try XCTUnwrap(rules.rules.first { $0.id == "mine.x" })
        XCTAssertTrue(mine.isCustom)
        XCTAssertFalse(mine.requiresAdmin, "файл користувача не може вмикати права адміна")
        let overridden = try XCTUnwrap(rules.rules.first { $0.id == "xcode.derivedData" })
        XCTAssertTrue(overridden.isCustom, "перекриття вбудованого id теж вважається власним правилом")
        let builtin = try XCTUnwrap(rules.rules.first { $0.id == "xcode.caches" })
        XCTAssertFalse(builtin.isCustom)
    }

    func testCustomRulesAreNeverSelectedAutomaticallyEvenWhenMarkedSafe() throws {
        let home = try FakeHome()
        let custom: CleanupRule = {
            var rule = try! makeRule(id: "mine.x", paths: ["~/Library/Caches/Foo"])
            rule.isCustom = true
            return rule
        }()
        let builtinLike = try makeRule(id: "builtin.x", paths: ["~/Library/Caches/Foo"])
        var entry = Entry(ruleID: "x", url: home.path("Library/Caches/Foo/a"))
        entry.measurement = DiskUsage(bytes: 1_000, fileCount: 1, lastModified: Date(), hadErrors: false)

        XCTAssertTrue(DiskScanner.isSelectedByDefault(entry, rule: builtinLike), "контроль: безпечне вбудоване вибирається")
        XCTAssertFalse(DiskScanner.isSelectedByDefault(entry, rule: custom))
        XCTAssertEqual(DiskScanner.defaultDecision(entry, rule: custom).reason, "власне правило: лише вручну")
    }
}

final class PrivilegedBatchHardeningTests: CleanerTestCase {
    func testOnlyAllowedSystemPathsAndAppsReachTheAdminCommand() throws {
        let home = try FakeHome()
        try makeApp(home, at: "Applications/Foo.app", bundleID: "com.vendor.foo", name: "Foo")
        try home.makeFile("Applications/notes.txt")
        let fake = FakeRunner()
        let runner = AppleScriptPrivilegedRunner(runner: fake, home: home.url)

        // Дозволене проходить і доходить до osascript.
        XCTAssertEqual(runner.removeItems(["/Library/Caches/a", home.path("Applications/Foo.app").path], prompt: "p"), .finished)
        XCTAssertEqual(fake.calls.count, 1)

        // Усе інше відхиляється ДО запуску команди (навіть якщо поруч є дозволене).
        for bad in [
            "/etc/hosts", "/Users/someone/Documents", "/Library/Caches", "/Library/Caches/../../etc/passwd",
            "/Library/Caches/a/../b", "Library/Caches/a", "/Applications/Nope.app", home.path("Applications/notes.txt").path,
            home.path("Documents/x").path, "/System/Library/CoreServices",
        ] {
            let before = fake.calls.count
            let outcome = runner.removeItems(["/Library/Caches/ok", bad], prompt: "p")
            guard case .failed = outcome else { return XCTFail("\(bad) мав бути відхилений, а вийшло \(outcome)") }
            XCTAssertEqual(fake.calls.count, before, "команда з правами адміна не повинна запускатись для \(bad)")
        }
    }

    func testCancellationIsRecognisedOnlyByTheRealErrorCode() throws {
        let fake = FakeRunner()
        let runner = AppleScriptPrivilegedRunner(runner: fake)
        fake.defaultResult = CommandResult(status: 1, error: "rm: /Library/Caches/file-128: Permission denied")
        XCTAssertEqual(runner.removeItems(["/Library/Caches/file-128"], prompt: "p"), .failed("rm: /Library/Caches/file-128: Permission denied"))
        fake.defaultResult = CommandResult(status: 1, error: "execution error: User canceled. (-128)")
        XCTAssertEqual(runner.removeItems(["/Library/Caches/a"], prompt: "p"), .cancelled)
    }
}

final class DuplicateAndLeftoverHardeningTests: CleanerTestCase {
    private func fileEntry(_ home: FakeHome, _ relative: String, rule: CleanupRule, keeper: Keeper? = nil) -> Entry {
        var entry = Entry(ruleID: rule.id, url: home.path(relative), scope: .userFile, action: .trashPaths, keeper: keeper)
        entry.measurement = DiskUsage(bytes: 5_000, fileCount: 1, lastModified: Date(), hadErrors: false)
        return entry
    }

    func testTheOriginalOfADuplicateIsNeverRemovedInTheSameBatch() throws {
        let home = try FakeHome()
        let original = try home.makeFile("Documents/original.bin", bytes: 5_000)
        try home.makeFile("Downloads/copy.bin", bytes: 5_000)
        let attributes = try FileManager.default.attributesOfItem(atPath: original.path)
        let keeper = Keeper(
            path: original.path, size: Int64(truncating: attributes[.size] as! NSNumber),
            modified: (attributes[.modificationDate] as! Date).timeIntervalSince1970.rounded(.down))
        let duplicates = FileScanner.duplicatesRule, media = FileCategory.other.rule
        let trasher = FakeTrasher(directory: home.path("tr"))

        // Користувач вибрав і оригінал (він же в «Великих файлах»), і його копію.
        let report = makeEngine(home, fileRoots: [home.path("Documents"), home.path("Downloads")], trasher: trasher).clean(
            entries: [
                fileEntry(home, "Documents/original.bin", rule: media),
                fileEntry(home, "Downloads/copy.bin", rule: duplicates, keeper: keeper),
            ], rules: [duplicates, media], dryRun: false)

        XCTAssertTrue(home.exists("Documents/original.bin"), "остання копія не повинна зникнути")
        XCTAssertFalse(home.exists("Downloads/copy.bin"))
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertEqual(trasher.trashedPaths, [home.path("Downloads/copy.bin").path])
    }

    func testSystemFoldersAreNeverTreatedAsLeftoversOfAThirdPartyApp() throws {
        let home = try FakeHome()
        let app = try makeApp(home, at: "Applications/Mailer.app", bundleID: "com.vendor.mailer", name: "Mailer")
        let guardian = ApplicationGuard(home: home.url, applicationRoots: [home.path("Applications")])

        func entry(companion: String, tokens: [String]) -> Entry {
            Entry(ruleID: "apps", url: app, scope: .application, action: .trashPaths,
                  companions: [home.path(companion)], ownerTokens: tokens)
        }
        // Назва програми збігається з системною текою: раніше це дозволяло «залишок» `Application Support/Mail`.
        for name in ["Mail", "AddressBook", "MobileSync", "CloudDocs", "Safari", "com.apple.notes", "group.com.apple.notes"] {
            XCTAssertThrowsError(
                try guardian.validate(entry(companion: "Library/Application Support/\(name)", tokens: ["com.vendor.mailer", name, "Mailer"])), name)
        }
        // Справжній залишок проходить.
        XCTAssertNoThrow(try guardian.validate(entry(companion: "Library/Application Support/Mailer", tokens: ["com.vendor.mailer", "Mailer"])))
        XCTAssertNoThrow(try guardian.validate(entry(companion: "Library/Caches/com.vendor.mailer", tokens: ["com.vendor.mailer", "Mailer"])))
        // Бандл Apple з іншим регістром теж захищений.
        XCTAssertTrue(ApplicationGuard.isProtected(bundleID: "COM.APPLE.Safari"))
    }

    func testMorePackageTypesAreNotDescendedInto() {
        for name in ["Windows11.vmwarevm", "Dev.pvm", "Catalog.lrlibrary", "Art.pxd", "Novel.scriv"] {
            XCTAssertFalse(UserFileGuard.shouldDescend(into: name), name)
        }
        XCTAssertTrue(UserFileGuard.shouldDescend(into: "Reports"))
    }
}

final class PrivacyHardeningTests: CleanerTestCase {
    func testLogsAreWrittenPrivatelyAndWithTildePaths() throws {
        let home = try FakeHome()
        try home.makeFile("Documents/big.mov", bytes: 5_000)
        let rule = FileCategory.media.rule
        var entry = Entry(ruleID: rule.id, url: home.path("Documents/big.mov"), scope: .userFile, action: .trashPaths)
        entry.measurement = DiskUsage(bytes: 5_000, fileCount: 1, lastModified: Date(), hadErrors: false)
        let report = makeEngine(home, fileRoots: [home.path("Documents")]).clean(entries: [entry], rules: [rule], dryRun: false)

        let log = try XCTUnwrap(report.logURL)
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("TRASHED 5000 ~/Documents/big.mov"), text)
        XCTAssertFalse(text.contains(home.url.path), "повний шлях до домашньої папки (з іменем користувача) не пишемо в лог")

        let fileMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? Int)
        let dirMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: log.deletingLastPathComponent().path)[.posixPermissions] as? Int)
        XCTAssertEqual(fileMode & 0o777, 0o600)
        XCTAssertEqual(dirMode & 0o777, 0o700)
    }

    func testDiagnosticReportsArePrivateToo() throws {
        let home = try FakeHome()
        let url = try XCTUnwrap(DiagnosticReport.write("x", home: home.url))
        XCTAssertEqual(try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) & 0o777, 0o600)
    }

    func testReportRedactsUserNamesAndDeviceIdentifiers() {
        let text = DiagnosticReport.redactPersonalIdentifiers("""
        /Users/jane.doe/Documents/a.psd
        /Users/Shared/Adobe
        backup 00008110-001A2B3C4D5E6F78 and 0123456789abcdef0123456789abcdef01234567
        ordinary text with /Users in it
        """)
        XCTAssertTrue(text.contains("/Users/<user>/Documents/a.psd"))
        XCTAssertFalse(text.contains("jane.doe"))
        XCTAssertTrue(text.contains("/Users/Shared/Adobe"))
        XCTAssertFalse(text.contains("001A2B3C4D5E6F78"))
        XCTAssertFalse(text.contains("0123456789abcdef"))
        XCTAssertTrue(text.contains("ordinary text with /Users in it"))
    }

    func testIPhoneBackupsAreNotNamedInTheReport() throws {
        let home = try FakeHome()
        let rule = CleanupRule(id: "backups", group: "g", title: "Backups", detail: "d", risk: .careful)
        let udid = "00008110-001A2B3C4D5E6F78"
        var entry = Entry(
            ruleID: rule.id, url: home.path("Library/Application Support/MobileSync/Backup/\(udid)"), name: "Jane's iPhone",
            scope: .backup, action: .trashPaths)
        entry.measurement = DiskUsage(bytes: 9_000, fileCount: 1, lastModified: Date(), hadErrors: false)
        let text = DiagnosticReport.render(DiagnosticInput(
            appVersion: "1", dryRun: true, macOSVersion: "26", architecture: "arm64", fullDiskAccess: true, disk: nil,
            projectRoots: [], fileSettings: nil, groups: [CleanupGroup(id: "g", title: "G", symbol: "x")],
            results: [RuleResult(rule: rule, entries: [entry])], selectedIDs: [], ruleBlocks: [:],
            blockReason: { _, _ in nil }, apps: [], survey: [], home: home.url))
        XCTAssertFalse(text.contains("Jane"), text)
        XCTAssertFalse(text.contains(udid), text)
        XCTAssertTrue(text.contains("MobileSync/Backup/<backup>"), text)
    }
}
