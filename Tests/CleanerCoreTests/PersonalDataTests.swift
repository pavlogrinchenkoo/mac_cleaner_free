import XCTest
@testable import CleanerCore

// MARK: - Охоронець особистих файлів

final class UserFileGuardTests: CleanerTestCase {
    private func make() throws -> (FakeHome, UserFileGuard) {
        let home = try FakeHome()
        return (home, UserFileGuard(home: home.url, roots: [home.path("Downloads"), home.path("Documents")]))
    }

    func testAllowsRegularFilesInUserFolders() throws {
        let (home, guardian) = try make()
        try home.makeFile("Downloads/movie.mov")
        try home.makeFile("Documents/Design/logo.psd")
        XCTAssertNoThrow(try guardian.validate(home.path("Downloads/movie.mov")))
        XCTAssertNoThrow(try guardian.validate(home.path("Documents/Design/logo.psd")))
    }

    func testRejectsHiddenPackagesArtifactsAndOutsideRoots() throws {
        let (home, guardian) = try make()
        try home.makeFile("Downloads/.secret.mov")
        try home.makeFile("Documents/Photos.photoslibrary/originals/a.jpg")
        try home.makeFile("Documents/App.app/Contents/MacOS/app")
        try home.makeFile("Documents/proj/node_modules/dep/x.bin")
        try home.makeFile("Documents/.hidden/inner.mov")
        try home.makeFile("Desktop/file.mov")
        try home.makeFile("Library/Mail/V10/msg.emlx")
        for path in [
            "Downloads/.secret.mov", "Documents/Photos.photoslibrary/originals/a.jpg", "Documents/App.app/Contents/MacOS/app",
            "Documents/proj/node_modules/dep/x.bin", "Documents/.hidden/inner.mov", "Desktop/file.mov", "Library/Mail/V10/msg.emlx",
        ] {
            XCTAssertThrowsError(try guardian.validate(home.path(path)), path)
        }
    }

    func testRejectsDirectoriesSymlinksAndRoots() throws {
        let (home, guardian) = try make()
        let real = try home.makeFile("Documents/real.bin")
        try FileManager.default.createDirectory(at: home.path("Downloads/folder"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.path("Downloads/link.bin"), withDestinationURL: real)
        XCTAssertThrowsError(try guardian.validate(home.path("Downloads/folder")), "тека, а не файл")
        XCTAssertThrowsError(try guardian.validate(home.path("Downloads/link.bin")), "symlink")
        XCTAssertThrowsError(try guardian.validate(home.path("Downloads")), "сам корінь")
        XCTAssertThrowsError(try guardian.validate(home.path("Downloads/missing.bin")), "не існує")
    }

    func testInvalidRootsAreDropped() throws {
        let home = try FakeHome()
        let guardian = UserFileGuard(home: home.url, roots: [home.url, home.path("Library"), home.path(".ssh"), home.path("Documents")])
        XCTAssertEqual(guardian.roots.map(\.lastPathComponent), ["Documents"])
    }
}

// MARK: - Пошук файлів

final class FileScannerTests: CleanerTestCase {
    private func settings(_ home: FakeHome, excluded: [URL] = []) -> FileScanSettings {
        FileScanSettings(
            roots: ["Downloads", "Desktop", "Documents", "Movies"].map { home.path($0) }, excludedRoots: excluded,
            minLargeBytes: 150_000, minDuplicateBytes: 100_000, minInstallerBytes: 50_000)
    }

    private func results(_ home: FakeHome, excluded: [URL] = []) -> [String: [Entry]] {
        Dictionary(uniqueKeysWithValues: FileScanner.results(settings: settings(home, excluded: excluded), home: home.url)
            .map { ($0.id, $0.entries) })
    }

    func testCategorizesLargeFilesAndSkipsSmallOnes() throws {
        let home = try FakeHome()
        try home.makeFile("Movies/clip.mov", bytes: 300_000)
        try home.makeFile("Documents/archive.zip", bytes: 250_000)
        try home.makeFile("Documents/poster.psd", bytes: 400_000)
        try home.makeFile("Documents/data.bin", bytes: 200_000)
        try home.makeFile("Documents/small.mov", bytes: 20_000)

        let found = results(home)
        XCTAssertEqual(found["files.large.media"]?.map(\.name), ["clip.mov"])
        XCTAssertEqual(found["files.large.archives"]?.map(\.name), ["archive.zip"])
        XCTAssertEqual(found["files.large.design"]?.map(\.name), ["poster.psd"])
        XCTAssertEqual(found["files.large.other"]?.map(\.name), ["data.bin"])

        let entry = try XCTUnwrap(found["files.large.media"]?.first)
        XCTAssertEqual(entry.scope, .userFile)
        XCTAssertEqual(entry.action, .trashPaths)
        XCTAssertGreaterThanOrEqual(entry.presetUsage?.bytes ?? 0, 300_000)
        XCTAssertEqual(entry.subtitle, "~/Movies".replacingOccurrences(of: "~", with: "~"))
    }

    func testSkipsHiddenPackagesReposArtifactsAndExcludedRoots() throws {
        let home = try FakeHome()
        try home.makeFile("Documents/.hidden.mov", bytes: 300_000)
        try home.makeFile("Documents/Lib.photoslibrary/originals/big.mov", bytes: 300_000)
        try home.makeFile("Documents/repo/.git/HEAD")
        try home.makeFile("Documents/repo/assets/big.mov", bytes: 300_000)
        try home.makeFile("Documents/app/node_modules/dep/big.bin", bytes: 300_000)
        try home.makeFile("Documents/Projects/work/big.mov", bytes: 300_000)
        try home.makeFile("Documents/ok/visible.mov", bytes: 310_000)
        let real = try home.makeFile("Documents/real.mov", bytes: 320_000)
        try FileManager.default.createSymbolicLink(at: home.path("Documents/link.mov"), withDestinationURL: real)

        let found = results(home, excluded: [home.path("Documents/Projects")])
        let names = Set((found["files.large.media"] ?? []).map(\.name))
        XCTAssertEqual(names, ["visible.mov", "real.mov"])
    }

    func testInstallersOnlyInDownloadsAndDesktop() throws {
        let home = try FakeHome()
        try home.makeFile("Downloads/App.dmg", bytes: 120_000)
        try home.makeFile("Desktop/Setup.pkg", bytes: 130_000)
        try home.makeFile("Documents/Keep.dmg", bytes: 140_000)
        try home.makeFile("Downloads/notes.txt", bytes: 150_000)
        try home.makeFile("Downloads/Huge.dmg", bytes: 400_000)

        let found = results(home)
        XCTAssertEqual(Set((found["files.installers"] ?? []).map(\.name)), ["App.dmg", "Setup.pkg", "Huge.dmg"])
        // Інсталятор не показуємо вдруге серед великих архівів.
        XCTAssertFalse((found["files.large.archives"] ?? []).contains { $0.name == "Huge.dmg" })
        XCTAssertTrue((found["files.large.archives"] ?? []).contains { $0.name == "Keep.dmg" } == false, "Keep.dmg меншого за поріг розміру")
    }

    func testFindsDuplicatesAndKeepsOneOriginal() throws {
        let home = try FakeHome()
        let content = Data(repeating: 0x11, count: 200_000)
        for path in ["Downloads/photo-copy.bin", "Documents/Photos/photo.bin", "Desktop/photo (1).bin"] {
            let url = home.path(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url)
        }
        // Той самий розмір, інший вміст: не дублікат.
        try Data(repeating: 0x22, count: 200_000).write(to: home.path("Documents/other.bin"))
        // Дрібні копії нижче порога.
        try home.makeFile("Documents/tiny1.bin", bytes: 1_000)
        try home.makeFile("Documents/tiny2.bin", bytes: 1_000)

        let found = results(home)
        let duplicates = try XCTUnwrap(found["files.duplicates"])
        XCTAssertEqual(Set(duplicates.map(\.name)), ["photo-copy.bin", "photo (1).bin"], "оригінал у Documents лишається")
        for entry in duplicates {
            XCTAssertEqual(entry.keeper?.path, home.path("Documents/Photos/photo.bin").path)
            XCTAssertEqual(entry.keeper?.size, 200_000)
            XCTAssertTrue(entry.subtitle?.hasPrefix("Копія: ") == true)
        }
        // Копії не показуються ще й серед великих файлів.
        let large = (found["files.large.other"] ?? []).map(\.name)
        XCTAssertFalse(large.contains("photo-copy.bin"))
        XCTAssertTrue(large.contains("photo.bin"), "оригінал можна бачити серед великих")
    }

    func testHardLinksAreNotDuplicates() throws {
        let home = try FakeHome()
        let original = try home.makeFile("Documents/a.bin", bytes: 300_000)
        try FileManager.default.linkItem(at: original, to: home.path("Documents/b.bin"))
        XCTAssertNil(results(home)["files.duplicates"])
    }

    func testKeeperPrefersPermanentLocationThenOlder() {
        let home = URL(fileURLWithPath: "/Users/u")
        func info(_ path: String, created: TimeInterval) -> FileInfo {
            FileInfo(url: URL(fileURLWithPath: path), allocatedBytes: 1, logicalBytes: 1, modified: created, created: created, device: 1, inode: UInt64(path.hashValue & 0xFFFF), linkCount: 1)
        }
        let downloads = info("/Users/u/Downloads/a.bin", created: 100)
        let documents = info("/Users/u/Documents/a.bin", created: 500)
        XCTAssertEqual(DuplicateFinder.chooseKeeper([downloads, documents], home: home).url.path, documents.url.path)
        let older = info("/Users/u/Documents/old.bin", created: 50)
        XCTAssertEqual(DuplicateFinder.chooseKeeper([documents, older], home: home).url.path, older.url.path)
    }

    func testDefaultRootsOnlyExistingUserFolders() throws {
        let home = try FakeHome()
        try FileManager.default.createDirectory(at: home.path("Downloads"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.path("Movies"), withIntermediateDirectories: true)
        XCTAssertEqual(FileScanSettings.defaultRoots(home: home.url).map(\.lastPathComponent), ["Downloads", "Movies"])
    }

    func testCategoryByExtension() {
        XCTAssertEqual(FileCategory.category(forExtension: "MOV"), .media)
        XCTAssertEqual(FileCategory.category(forExtension: "dmg"), .archives)
        XCTAssertEqual(FileCategory.category(forExtension: "psd"), .design)
        XCTAssertEqual(FileCategory.category(forExtension: "xyz"), .other)
    }
}

// MARK: - Рушій: Кошик і дублікати

final class TrashEngineTests: CleanerTestCase {
    private func fileEntry(_ home: FakeHome, _ relative: String, rule: CleanupRule, keeper: Keeper? = nil, bytes: Int64 = 5_000) -> Entry {
        var entry = Entry(
            ruleID: rule.id, url: home.path(relative), scope: .userFile, action: .trashPaths, keeper: keeper)
        entry.measurement = DiskUsage(bytes: bytes, fileCount: 1, lastModified: nil, hadErrors: false)
        return entry
    }

    func testTrashesFileInDocumentsAndKeepsAccounting() throws {
        let home = try FakeHome()
        try home.makeFile("Documents/big.mov", bytes: 5_000)
        let trasher = FakeTrasher(directory: home.path("tr"))
        let engine = makeEngine(home, fileRoots: [home.path("Documents")], trasher: trasher)
        let rule = FileCategory.media.rule
        let report = engine.clean(entries: [fileEntry(home, "Documents/big.mov", rule: rule)], rules: [rule], dryRun: false)

        XCTAssertFalse(home.exists("Documents/big.mov"))
        XCTAssertEqual(trasher.trashedPaths, [home.path("Documents/big.mov").path])
        XCTAssertEqual(report.trashedBytes, 5_000)
        XCTAssertEqual(report.freedBytes, 0, "у Кошику місце ще не звільнене")
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(try String(contentsOf: XCTUnwrap(report.logURL), encoding: .utf8).contains("TRASHED"))
    }

    func testDryRunNeverTouchesFilesAndCountsTrashSeparately() throws {
        let home = try FakeHome()
        try home.makeFile("Documents/big.mov", bytes: 5_000)
        let trasher = FakeTrasher(directory: home.path("tr"))
        let rule = FileCategory.media.rule
        let report = makeEngine(home, fileRoots: [home.path("Documents")], trasher: trasher)
            .clean(entries: [fileEntry(home, "Documents/big.mov", rule: rule)], rules: [rule], dryRun: true)
        XCTAssertTrue(home.exists("Documents/big.mov"))
        XCTAssertTrue(trasher.trashedPaths.isEmpty)
        XCTAssertEqual(report.trashedBytes, 5_000)
        XCTAssertEqual(report.freedBytes, 0)
    }

    func testFilesOutsideUserFoldersAreRefused() throws {
        let home = try FakeHome()
        try home.makeFile("Library/Mail/V10/msg.emlx", bytes: 5_000)
        try home.makeFile("Documents/.hidden.mov", bytes: 5_000)
        try home.makeFile("Documents/Lib.photoslibrary/a.jpg", bytes: 5_000)
        let trasher = FakeTrasher(directory: home.path("tr"))
        let rule = FileCategory.other.rule
        let report = makeEngine(home, fileRoots: [home.path("Documents")], trasher: trasher).clean(
            entries: [
                fileEntry(home, "Library/Mail/V10/msg.emlx", rule: rule),
                fileEntry(home, "Documents/.hidden.mov", rule: rule),
                fileEntry(home, "Documents/Lib.photoslibrary/a.jpg", rule: rule),
                fileEntry(home, "Documents", rule: rule),
            ], rules: [rule], dryRun: false)
        XCTAssertEqual(report.skipped.count, 4)
        XCTAssertTrue(trasher.trashedPaths.isEmpty)
    }

    func testDuplicateIsTrashedOnlyWhileKeeperIsUntouched() throws {
        let home = try FakeHome()
        let keeperFile = try home.makeFile("Documents/original.bin", bytes: 5_000)
        try home.makeFile("Downloads/copy.bin", bytes: 5_000)
        let rule = FileScanner.duplicatesRule
        let attributes = try FileManager.default.attributesOfItem(atPath: keeperFile.path)
        let keeper = Keeper(
            path: keeperFile.path, size: Int64(truncating: attributes[.size] as! NSNumber),
            modified: (attributes[.modificationDate] as! Date).timeIntervalSince1970.rounded(.down))
        let roots = [home.path("Documents"), home.path("Downloads")]

        // 1. Оригінал на місці: копію можна прибрати.
        let trasher = FakeTrasher(directory: home.path("tr"))
        var report = makeEngine(home, fileRoots: roots, trasher: trasher).clean(
            entries: [fileEntry(home, "Downloads/copy.bin", rule: rule, keeper: keeper)], rules: [rule], dryRun: false)
        XCTAssertEqual(report.trashedBytes, 5_000)
        XCTAssertTrue(home.exists("Documents/original.bin"))

        // 2. Оригінал змінили після скану: копію не чіпаємо.
        try home.makeFile("Downloads/copy2.bin", bytes: 5_000)
        try Data(repeating: 0x99, count: 7_000).write(to: keeperFile)
        report = makeEngine(home, fileRoots: roots, trasher: trasher).clean(
            entries: [fileEntry(home, "Downloads/copy2.bin", rule: rule, keeper: keeper)], rules: [rule], dryRun: false)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertTrue(home.exists("Downloads/copy2.bin"))

        // 3. Оригінал зник: теж не чіпаємо.
        try home.makeFile("Downloads/copy3.bin", bytes: 5_000)
        try FileManager.default.removeItem(at: keeperFile)
        report = makeEngine(home, fileRoots: roots, trasher: trasher).clean(
            entries: [fileEntry(home, "Downloads/copy3.bin", rule: rule, keeper: keeper)], rules: [rule], dryRun: false)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertTrue(home.exists("Downloads/copy3.bin"))
    }

    func testDuplicateWithoutKeeperIsRefused() throws {
        let home = try FakeHome()
        try home.makeFile("Downloads/copy.bin", bytes: 5_000)
        let rule = FileScanner.duplicatesRule
        let report = makeEngine(home, fileRoots: [home.path("Downloads")]).clean(
            entries: [fileEntry(home, "Downloads/copy.bin", rule: rule, keeper: nil)], rules: [rule], dryRun: false)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertTrue(home.exists("Downloads/copy.bin"))
    }

    func testKeeperCannotBeTheEntryItself() throws {
        let home = try FakeHome()
        let file = try home.makeFile("Downloads/only.bin", bytes: 5_000)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let keeper = Keeper(path: file.path, size: 5_000, modified: (attributes[.modificationDate] as! Date).timeIntervalSince1970.rounded(.down))
        let rule = FileScanner.duplicatesRule
        let report = makeEngine(home, fileRoots: [home.path("Downloads")]).clean(
            entries: [fileEntry(home, "Downloads/only.bin", rule: rule, keeper: keeper)], rules: [rule], dryRun: false)
        XCTAssertEqual(report.skipped.count, 1, "єдину копію не прибираємо")
        XCTAssertTrue(home.exists("Downloads/only.bin"))
    }

    func testTrashFailureIsReported() throws {
        let home = try FakeHome()
        try home.makeFile("Downloads/a.bin", bytes: 5_000)
        let trasher = FakeTrasher(directory: home.path("tr"))
        trasher.failing = [home.path("Downloads/a.bin").path]
        let rule = FileCategory.other.rule
        let report = makeEngine(home, fileRoots: [home.path("Downloads")], trasher: trasher)
            .clean(entries: [fileEntry(home, "Downloads/a.bin", rule: rule)], rules: [rule], dryRun: false)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.trashedBytes, 0)
        XCTAssertTrue(home.exists("Downloads/a.bin"))
    }

    func testPersonalDataIsNeverSelectedByDefault() throws {
        let safeRule = try makeRule(paths: ["~/x"])
        for scope in [EntryScope.userFile, .backup, .application] {
            var entry = Entry(ruleID: safeRule.id, url: URL(fileURLWithPath: "/tmp/x"), scope: scope)
            entry.measurement = DiskUsage(bytes: 1, fileCount: 1, lastModified: Date(timeIntervalSince1970: 0), hadErrors: false)
            XCTAssertFalse(DiskScanner.isSelectedByDefault(entry, rule: safeRule), "\(scope)")
        }
    }
}

// MARK: - Резервні копії iPhone

final class BackupTests: CleanerTestCase {
    private let udid = "00008110-001A2B3C4D5E6F78"

    private func makeBackup(_ home: FakeHome, id: String? = nil, encrypted: Bool = false) throws {
        let dir = home.path("Library/Application Support/MobileSync/Backup/\(id ?? udid)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 50_000).write(to: dir.appendingPathComponent("blob.bin"))
        let info: [String: Any] = [
            "Device Name": "iPhone Оксани", "Product Name": "iPhone 15", "Product Version": "17.4",
            "Last Backup Date": Date(timeIntervalSinceNow: -40 * 86_400),
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: dir.appendingPathComponent("Info.plist"))
        let manifest: [String: Any] = ["IsEncrypted": encrypted]
        try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0).write(to: dir.appendingPathComponent("Manifest.plist"))
    }

    func testDiscoversBackupWithMetadata() throws {
        let home = try FakeHome()
        try makeBackup(home, encrypted: true)
        try FileManager.default.createDirectory(at: home.path("Library/Application Support/MobileSync/Backup/not-a-backup"), withIntermediateDirectories: true)

        let result = BackupProvider.discover(home: home.url)
        XCTAssertNil(result.accessError)
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(result.entries.count, 1, "службові папки без UDID ігноруємо")
        XCTAssertEqual(entry.name, "iPhone Оксани")
        XCTAssertTrue(try XCTUnwrap(entry.subtitle).contains("iPhone 15"))
        XCTAssertTrue(try XCTUnwrap(entry.subtitle).contains("17.4"))
        XCTAssertTrue(try XCTUnwrap(entry.subtitle).contains("зашифрована"))
        XCTAssertEqual(entry.scope, .backup)
        XCTAssertEqual(entry.action, .trashPaths)
        XCTAssertNotNil(entry.activityDate)
    }

    func testMissingFolderMeansNoBackupsAndNoError() throws {
        let home = try FakeHome()
        let result = BackupProvider.discover(home: home.url)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertNil(result.accessError)
    }

    func testUnreadableFolderReportsFullDiskAccess() throws {
        let home = try FakeHome()
        try makeBackup(home)
        let root = home.path("Library/Application Support/MobileSync/Backup")
        chmod(root.path, 0o000)
        defer { chmod(root.path, 0o755) }
        let result = BackupProvider.discover(home: home.url)
        XCTAssertNotNil(result.accessError)
    }

    func testGuardAcceptsOnlyDirectBackupFolders() throws {
        let home = try FakeHome()
        try makeBackup(home)
        let guardian = BackupGuard(home: home.url)
        let root = "Library/Application Support/MobileSync/Backup"
        XCTAssertNoThrow(try guardian.validate(home.path("\(root)/\(udid)")))
        XCTAssertThrowsError(try guardian.validate(home.path(root)))
        XCTAssertThrowsError(try guardian.validate(home.path("\(root)/\(udid)/blob.bin")))
        XCTAssertThrowsError(try guardian.validate(home.path("Library/Application Support/MobileSync")))
        XCTAssertThrowsError(try guardian.validate(home.path("Documents")))
    }

    func testBackupIsMovedToTrashByEngine() throws {
        let home = try FakeHome()
        try makeBackup(home)
        let discovered = BackupProvider.discover(home: home.url)
        var entry = try XCTUnwrap(discovered.entries.first)
        entry.measurement = DiskSize.measure(entry.url)
        let trasher = FakeTrasher(directory: home.path("tr"))
        let report = makeEngine(home, trasher: trasher).clean(entries: [entry], rules: [BackupProvider.rule], dryRun: false)
        XCTAssertEqual(report.trashedBytes, entry.bytes)
        XCTAssertFalse(home.exists("Library/Application Support/MobileSync/Backup/\(udid)"))
    }
}

// MARK: - Деінсталятор

final class UninstallerTests: CleanerTestCase {
    private func setup() throws -> (FakeHome, URL) {
        let home = try FakeHome()
        let apps = home.path("Apps")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try makeApp(home, at: "Apps/Foo.app", bundleID: "com.vendor.foo", name: "Foo", version: "2.1")
        try makeApp(home, at: "Apps/Safari.app", bundleID: "com.apple.Safari", name: "Safari")
        try makeApp(home, at: "Apps/Cleaner.app", bundleID: ApplicationGuard.ownBundleID, name: "Cleaner")
        // Свої залишки Foo.
        for path in [
            "Library/Caches/com.vendor.foo/data", "Library/Containers/com.vendor.foo/Data/x",
            "Library/Preferences/com.vendor.foo.plist", "Library/Application Support/Foo/db",
            "Library/Group Containers/ABC123.com.vendor.foo/x", "Library/Saved Application State/com.vendor.foo.savedState/x",
            "Library/Preferences/ByHost/com.vendor.foo.ABCDEF.plist",
        ] { try home.makeFile(path) }
        // Чужі, схожі за назвою: чіпати не можна.
        for path in [
            "Library/Caches/com.vendor.foobar/data", "Library/Application Support/FooBar/db",
            "Library/Preferences/com.vendor.foo2.plist", "Library/Application Support/Other/foo.txt",
        ] { try home.makeFile(path) }
        return (home, apps)
    }

    func testFindsThirdPartyAppsOnly() throws {
        let (home, apps) = try setup()
        let result = AppProvider.discover(home: home.url, roots: [apps])
        XCTAssertEqual(result.entries.map(\.name), ["Foo"], "Apple і сам Cleaner не показуємо")
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.scope, .application)
        XCTAssertEqual(entry.ownerName, "com.vendor.foo")
        XCTAssertEqual(entry.ownerTokens.first, "com.vendor.foo")
        XCTAssertTrue(try XCTUnwrap(entry.subtitle).contains("версія 2.1"))
        XCTAssertFalse(entry.needsAdmin, "власник цього тесту — поточний користувач")
    }

    func testLeftoversMatchOnlyThisApp() throws {
        let (home, apps) = try setup()
        let app = try XCTUnwrap(AppProvider.installedApps(roots: [apps]).first)
        let leftovers = AppProvider.leftovers(for: app, home: home.url).map { $0.path.replacingOccurrences(of: home.url.path + "/", with: "") }.sorted()
        XCTAssertEqual(leftovers, [
            "Library/Application Support/Foo", "Library/Caches/com.vendor.foo", "Library/Containers/com.vendor.foo",
            "Library/Group Containers/ABC123.com.vendor.foo", "Library/Preferences/ByHost/com.vendor.foo.ABCDEF.plist",
            "Library/Preferences/com.vendor.foo.plist", "Library/Saved Application State/com.vendor.foo.savedState",
        ])
    }

    func testUninstallMovesAppAndLeftoversToTrash() throws {
        let (home, apps) = try setup()
        var entry = try XCTUnwrap(AppProvider.discover(home: home.url, roots: [apps]).entries.first)
        entry.measurement = DiskSize.measure(entry.url)
        let trasher = FakeTrasher(directory: home.path("tr"))
        let report = makeEngine(home, applicationRoots: [apps], trasher: trasher).clean(
            entries: [entry], rules: [AppProvider.rule], dryRun: false)

        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertFalse(home.exists("Apps/Foo.app"))
        XCTAssertFalse(home.exists("Library/Caches/com.vendor.foo"))
        XCTAssertFalse(home.exists("Library/Application Support/Foo"))
        // Чуже лишається.
        XCTAssertTrue(home.exists("Library/Caches/com.vendor.foobar"))
        XCTAssertTrue(home.exists("Library/Application Support/FooBar"))
        XCTAssertTrue(home.exists("Library/Preferences/com.vendor.foo2.plist"))
        XCTAssertTrue(home.exists("Apps/Safari.app"))
    }

    func testGuardRejectsForeignLeftoversAndSystemApps() throws {
        let (home, apps) = try setup()
        let valid = try XCTUnwrap(AppProvider.discover(home: home.url, roots: [apps]).entries.first)
        let policy = SafetyPolicy(home: home.url, applicationRoots: [apps])
        XCTAssertNoThrow(try policy.validate(valid))

        var foreign = valid
        foreign.companions.append(home.path("Library/Caches/com.vendor.foobar"))
        XCTAssertThrowsError(try policy.validate(foreign), "чужий кеш")

        var documents = valid
        documents.companions.append(home.path("Documents"))
        XCTAssertThrowsError(try policy.validate(documents), "поза теками Library")

        var safari = valid
        safari = Entry(ruleID: valid.ruleID, url: apps.appendingPathComponent("Safari.app"), scope: .application,
                       action: .trashPaths, ownerTokens: ["com.apple.Safari"])
        XCTAssertThrowsError(try policy.validate(safari), "програми Apple")

        let outside = Entry(ruleID: valid.ruleID, url: home.path("Documents/Foo.app"), scope: .application,
                            action: .trashPaths, ownerTokens: ["com.vendor.foo"])
        XCTAssertThrowsError(try policy.validate(outside), "поза /Applications")

        var wrongToken = valid
        wrongToken = Entry(ruleID: valid.ruleID, url: valid.url, scope: .application, action: .trashPaths, ownerTokens: ["com.other.id"])
        XCTAssertThrowsError(try policy.validate(wrongToken), "bundle ID не збігається")
    }

    func testRootOwnedAppGoesThroughPasswordPromptAndLeftoversFollow() throws {
        let (home, apps) = try setup()
        var entry = try XCTUnwrap(AppProvider.discover(home: home.url, roots: [apps]).entries.first)
        entry.needsAdmin = true
        entry.measurement = DiskSize.measure(entry.url)
        let privileged = FakePrivileged()
        let trasher = FakeTrasher(directory: home.path("tr"))
        let report = makeEngine(home, applicationRoots: [apps], privileged: privileged, trasher: trasher).clean(
            entries: [entry], rules: [AppProvider.rule], dryRun: false)

        XCTAssertEqual(privileged.receivedBatches, [[home.path("Apps/Foo.app").path]], "пароль лише для самого .app")
        XCTAssertFalse(home.exists("Apps/Foo.app"))
        XCTAssertFalse(home.exists("Library/Caches/com.vendor.foo"), "залишки переносимо в Кошик після успіху")
        XCTAssertTrue(trasher.trashedPaths.contains(home.path("Library/Caches/com.vendor.foo").path))
        XCTAssertTrue(report.failures.isEmpty)
    }

    func testCancelledPasswordLeavesAppAndLeftoversUntouched() throws {
        let (home, apps) = try setup()
        var entry = try XCTUnwrap(AppProvider.discover(home: home.url, roots: [apps]).entries.first)
        entry.needsAdmin = true
        entry.measurement = DiskSize.measure(entry.url)
        let privileged = FakePrivileged()
        privileged.outcome = .cancelled
        let report = makeEngine(home, applicationRoots: [apps], privileged: privileged).clean(
            entries: [entry], rules: [AppProvider.rule], dryRun: false)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertTrue(home.exists("Apps/Foo.app"))
        XCTAssertTrue(home.exists("Library/Caches/com.vendor.foo"))
    }

    func testRunningAppIsBlocked() throws {
        let (home, apps) = try setup()
        var entry = try XCTUnwrap(AppProvider.discover(home: home.url, roots: [apps]).entries.first)
        entry.measurement = DiskUsage(bytes: 1, fileCount: 1, lastModified: nil, hadErrors: false)
        let running = RunningSnapshot(bundleIDs: ["com.vendor.foo"], appNames: ["foo"])
        XCTAssertEqual(DiskScanner.blockReason(for: entry, rule: AppProvider.rule, ruleBlock: nil, snapshot: running), "Застосунок запущений")
        XCTAssertNil(DiskScanner.blockReason(for: entry, rule: AppProvider.rule, ruleBlock: nil, snapshot: RunningSnapshot()))
    }
}

// MARK: - Кеші за власником

final class OwnerCacheTests: CleanerTestCase {
    private func rule() throws -> CleanupRule {
        try makeRule(
            id: "apps.electron",
            paths: ["~/Library/Application Support/*/{Cache,Code Cache,GPUCache}", "~/Library/Application Support/*/*/*/{Cache,Code Cache,GPUCache}"],
            granularity: "self", extra: "\"ownerFromPrefix\":true,\"skipRunningAppCaches\":true")
    }

    func testBraceGlobExpandsAlternatives() throws {
        let home = try FakeHome()
        try home.makeFile("Library/Application Support/App/Cache/a")
        try home.makeFile("Library/Application Support/App/Code Cache/a")
        try home.makeFile("Library/Application Support/App/Data/a")
        let matches = PathExpander.expand("~/Library/Application Support/*/{Cache,Code Cache}", home: home.url)
        XCTAssertEqual(Set(matches.map(\.lastPathComponent)), ["Cache", "Code Cache"])
    }

    func testCachesAreGroupedByOwnerAndBlockedWhenAppRuns() throws {
        let home = try FakeHome()
        for path in [
            "Library/Application Support/ZyxCanvas/DesktopProfile/v43/Cache/a", "Library/Application Support/ZyxCanvas/DesktopProfile/v43/Code Cache/a",
            "Library/Application Support/ZyxCanvas/DesktopProfile/v42/GPUCache/a", "Library/Application Support/QrsChat/Cache/a",
            "Library/Application Support/ZyxCanvas/DesktopProfile/v43/Local Storage/keep",
        ] { try home.makeFile(path) }
        let rule = try rule()
        let result = DiskScanner(ruleSet: makeRuleSet([rule]), home: home.url).discover()[0]

        XCTAssertEqual(result.entries.map(\.name), ["QrsChat", "ZyxCanvas"])
        let figma = try XCTUnwrap(result.entries.first { $0.name == "ZyxCanvas" })
        XCTAssertEqual(figma.companions.count, 2, "усі кеші однієї програми в одному елементі")
        XCTAssertEqual(figma.ownerName, "ZyxCanvas")
        XCTAssertTrue(try XCTUnwrap(figma.subtitle).hasPrefix("теки: 3"))

        let running = RunningSnapshot(bundleIDs: [], appNames: ["zyxcanvas"])
        XCTAssertEqual(DiskScanner.blockReason(for: figma, rule: rule, ruleBlock: nil, snapshot: running), "Застосунок запущений")
        let discord = try XCTUnwrap(result.entries.first { $0.name == "QrsChat" })
        XCTAssertNil(DiskScanner.blockReason(for: discord, rule: rule, ruleBlock: nil, snapshot: running))

        // Видалення чистить лише теки кешу, а не профіль.
        var measured = figma
        measured.measurement = DiskSize.measure(figma.url)
        let report = makeEngine(home).clean(entries: [measured], rules: [rule], dryRun: false)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(report.skipped.isEmpty, "\(report.skipped)")
        XCTAssertFalse(home.exists("Library/Application Support/ZyxCanvas/DesktopProfile/v43/Cache"))
        XCTAssertFalse(home.exists("Library/Application Support/ZyxCanvas/DesktopProfile/v42/GPUCache"))
        XCTAssertTrue(home.exists("Library/Application Support/ZyxCanvas/DesktopProfile/v43/Local Storage/keep"), "профіль лишається")
    }

    func testExcludeOwnersAndSandboxContainers() throws {
        let home = try FakeHome()
        try home.makeFile("Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches/a", bytes: 10_000)
        try home.makeFile("Library/Containers/com.vendor.paint/Data/Library/Caches/a", bytes: 10_000)
        let rule = try makeRule(
            id: "apps.sandbox", paths: ["~/Library/Containers/*/Data/Library/Caches"], granularity: "self",
            extra: "\"ownerFromPrefix\":true,\"excludeOwners\":[\"com.apple.*\"],\"skipRunningAppCaches\":true")
        let result = DiskScanner(ruleSet: makeRuleSet([rule]), home: home.url).discover()[0]
        XCTAssertEqual(result.entries.map(\.name), ["com.vendor.paint"])
        let running = RunningSnapshot(bundleIDs: ["com.vendor.paint"], appNames: [])
        XCTAssertNotNil(DiskScanner.blockReason(for: result.entries[0], rule: rule, ruleBlock: nil, snapshot: running))
    }

    func testBundlePatternsInBlockedByApps() throws {
        let snapshot = RunningSnapshot(bundleIDs: ["com.adobe.Photoshop", "com.adobe.acc.AdobeCreativeCloud"], appNames: [])
        let premiere = try makeRule(paths: ["~/x"], extra: "\"blockedByApps\":[\"com.adobe.PremierePro*\"]")
        let photoshop = try makeRule(paths: ["~/x"], extra: "\"blockedByApps\":[\"com.adobe.Photoshop*\"]")
        XCTAssertNil(RunningProbe.blockReason(for: premiere, snapshot: snapshot), "фонова служба Adobe не блокує Premiere")
        XCTAssertNotNil(RunningProbe.blockReason(for: photoshop, snapshot: snapshot))
    }

    func testOwnershipHeuristics() {
        let snapshot = RunningSnapshot(bundleIDs: ["com.google.Chrome"], appNames: ["google chrome", "visual studio code"])
        XCTAssertTrue(snapshot.ownsCache(named: "Google"))
        XCTAssertTrue(snapshot.ownsCache(named: "com.google.Chrome"))
        XCTAssertFalse(snapshot.ownsCache(named: "Figma"))
        XCTAssertFalse(snapshot.ownsCache(named: "app"), "надто короткі назви не збігаємо за вмістом")
    }
}
