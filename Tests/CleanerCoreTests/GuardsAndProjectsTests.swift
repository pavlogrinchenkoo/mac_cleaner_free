import XCTest
@testable import CleanerCore

final class ArtifactGuardTests: CleanerTestCase {
    private func make() throws -> (FakeHome, ArtifactGuard) {
        let home = try FakeHome()
        return (home, ArtifactGuard(home: home.url, roots: [home.path("Documents/Projects")]))
    }

    func testAllowsNodeModulesNextToPackageJson() throws {
        let (home, guardian) = try make()
        try home.makeFile("Documents/Projects/app/package.json")
        try home.makeFile("Documents/Projects/app/node_modules/dep/index.js")
        XCTAssertNoThrow(try guardian.validate(home.path("Documents/Projects/app/node_modules")))
    }

    func testRejectsWithoutProjectMarker() throws {
        let (home, guardian) = try make()
        try home.makeFile("Documents/Projects/orphan/node_modules/x")
        XCTAssertThrowsError(try guardian.validate(home.path("Documents/Projects/orphan/node_modules")))
        try home.makeFile("Documents/Projects/plain/build/x")
        XCTAssertThrowsError(try guardian.validate(home.path("Documents/Projects/plain/build")), "build без файлів проєкту")
    }

    func testRejectsNonArtifactNamesAndOutsideRoots() throws {
        let (home, guardian) = try make()
        try home.makeFile("Documents/Projects/app/package.json")
        try home.makeFile("Documents/Projects/app/src/main.js")
        XCTAssertThrowsError(try guardian.validate(home.path("Documents/Projects/app/src")))
        XCTAssertThrowsError(try guardian.validate(home.path("Documents/Projects/app")))
        XCTAssertThrowsError(try guardian.validate(home.path("Documents/Projects/app/package.json")))

        try home.makeFile("Documents/Other/app/package.json")
        try home.makeFile("Documents/Other/app/node_modules/x")
        XCTAssertThrowsError(try guardian.validate(home.path("Documents/Other/app/node_modules")), "поза папками проєктів")
    }

    func testRejectsNestedArtifacts() throws {
        let (home, guardian) = try make()
        try home.makeFile("Documents/Projects/app/package.json")
        try home.makeFile("Documents/Projects/app/node_modules/dep/package.json")
        try home.makeFile("Documents/Projects/app/node_modules/dep/node_modules/inner/x")
        XCTAssertThrowsError(try guardian.validate(home.path("Documents/Projects/app/node_modules/dep/node_modules"))) { error in
            guard case .nestedArtifact = error as? GuardError else { return XCTFail("\(error)") }
        }
    }

    func testBuildAcceptedForGradleFlutterAndXcode() throws {
        let (home, guardian) = try make()
        try home.makeFile("Documents/Projects/flutter/pubspec.yaml")
        try home.makeFile("Documents/Projects/flutter/build/x")
        try home.makeFile("Documents/Projects/android/build.gradle.kts")
        try home.makeFile("Documents/Projects/android/build/x")
        try FileManager.default.createDirectory(at: home.path("Documents/Projects/ios/Runner.xcodeproj"), withIntermediateDirectories: true)
        try home.makeFile("Documents/Projects/ios/build/x")
        for path in ["flutter", "android", "ios"] {
            XCTAssertNoThrow(try guardian.validate(home.path("Documents/Projects/\(path)/build")), path)
        }
    }

    func testVenvNeedsPyvenvCfg() throws {
        let (home, guardian) = try make()
        try home.makeFile("Documents/Projects/real/.venv/pyvenv.cfg")
        try home.makeFile("Documents/Projects/fake/.venv/readme.txt")
        XCTAssertNoThrow(try guardian.validate(home.path("Documents/Projects/real/.venv")))
        XCTAssertThrowsError(try guardian.validate(home.path("Documents/Projects/fake/.venv")))
    }

    func testRootValidation() throws {
        let home = try FakeHome()
        XCTAssertFalse(ArtifactGuard.isValidRoot(home.url, home: home.url), "домашня папка не може бути коренем")
        XCTAssertFalse(ArtifactGuard.isValidRoot(home.path("Library/Foo"), home: home.url))
        XCTAssertFalse(ArtifactGuard.isValidRoot(home.path(".ssh"), home: home.url))
        XCTAssertFalse(ArtifactGuard.isValidRoot(home.path(".Trash/x"), home: home.url))
        XCTAssertFalse(ArtifactGuard.isValidRoot(URL(fileURLWithPath: "/etc"), home: home.url))
        XCTAssertTrue(ArtifactGuard.isValidRoot(home.path("Documents/Projects"), home: home.url))
        let guardian = ArtifactGuard(home: home.url, roots: [home.url, home.path("Library/Foo"), home.path("src")])
        XCTAssertEqual(guardian.roots.map(\.lastPathComponent), ["src"])
    }

    func testRejectsSymlinkedProjectEscapingRoot() throws {
        let (home, guardian) = try make()
        let outside = try FakeHome()
        try outside.makeFile("package.json")
        try outside.makeFile("node_modules/x")
        try FileManager.default.createDirectory(at: home.path("Documents/Projects"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.path("Documents/Projects/link"), withDestinationURL: outside.url)
        XCTAssertThrowsError(try guardian.validate(home.path("Documents/Projects/link/node_modules")))
    }
}

final class SystemPathGuardTests: CleanerTestCase {
    func testDefaultRootsAreMinimal() {
        XCTAssertEqual(SystemPathGuard.defaultRoots, ["/Library/Caches", "/Library/Logs"])
    }

    func testAllowsOnlyInsideRoots() throws {
        let home = try FakeHome()
        let root = home.path("sys/Caches")
        let guardian = SystemPathGuard(roots: [root.path])
        XCTAssertNoThrow(try guardian.validate(root.appendingPathComponent("com.foo.app")))
        XCTAssertThrowsError(try guardian.validate(root), "сам корінь видаляти не можна")
        XCTAssertThrowsError(try guardian.validate(URL(fileURLWithPath: "/etc/hosts")))
        XCTAssertThrowsError(try guardian.validate(URL(fileURLWithPath: "/Library/Developer/CoreSimulator")))
        XCTAssertThrowsError(try guardian.validate(URL(fileURLWithPath: root.path + "/../Secrets")))
        XCTAssertThrowsError(try guardian.validate(home.path("sys/Caches-evil/x")), "сусід з тим самим префіксом")
    }

    func testRejectsSymlinkEscapingRoot() throws {
        let home = try FakeHome()
        let root = home.path("sys/Caches")
        let outside = try FakeHome()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside.url)
        XCTAssertThrowsError(try SystemPathGuard(roots: [root.path]).validate(root.appendingPathComponent("link/child")))
    }
}

final class ProjectScannerTests: CleanerTestCase {
    private func discover(_ home: FakeHome) -> [String: [Entry]] {
        let guardian = ArtifactGuard(home: home.url, roots: [home.path("Projects")])
        return Dictionary(uniqueKeysWithValues: ProjectScanner.discover(guard: guardian).map { ($0.id, $0.entries) })
    }

    func testFindsArtifactsAndNamesProjects() throws {
        let home = try FakeHome()
        try home.makeFile("Projects/appA/package.json")
        try home.makeFile("Projects/appA/node_modules/pkg/index.js")
        try home.makeFile("Projects/appA/src/main.js")
        try home.makeFile("Projects/flutter/pubspec.yaml")
        try home.makeFile("Projects/flutter/.dart_tool/x")
        try home.makeFile("Projects/flutter/build/x")
        try home.makeFile("Projects/flutter/ios/Podfile")
        try home.makeFile("Projects/flutter/ios/Pods/x")
        try FileManager.default.createDirectory(at: home.path("Projects/flutter/ios/Runner.xcodeproj"), withIntermediateDirectories: true)
        try home.makeFile("Projects/flutter/ios/build/x")
        try home.makeFile("Projects/venvapp/.venv/pyvenv.cfg")

        let found = discover(home)
        XCTAssertEqual(found["project.node_modules"]?.map(\.name), ["appA"])
        XCTAssertEqual(found["project.dart"]?.map(\.name), ["flutter"])
        XCTAssertEqual(found["project.pods"]?.map(\.name), ["flutter/ios"])
        XCTAssertEqual(found["project.build"]?.map(\.name), ["flutter", "flutter/ios"])
        XCTAssertEqual(found["project.venv"]?.map(\.name), ["venvapp"])
        XCTAssertEqual(found["project.node_modules"]?.first?.subtitle, "node_modules")
        XCTAssertTrue(found.values.joined().allSatisfy { $0.scope == .project })
    }

    func testIgnoresLookalikesAndNestedArtifacts() throws {
        let home = try FakeHome()
        try home.makeFile("Projects/orphan/node_modules/x")
        try home.makeFile("Projects/plain/build/output.txt")
        try home.makeFile("Projects/app/package.json")
        try home.makeFile("Projects/app/node_modules/dep/package.json")
        try home.makeFile("Projects/app/node_modules/dep/node_modules/inner/x")
        try home.makeFile("Projects/app/.git/objects/x")

        let found = discover(home)
        XCTAssertEqual(found["project.node_modules"]?.map(\.name), ["app"], "лише верхній node_modules справжнього проєкту")
        XCTAssertNil(found["project.build"])
    }

    func testArtifactDirectlyUnderRootUsesRootName() throws {
        let home = try FakeHome()
        try home.makeFile("Projects/package.json")
        try home.makeFile("Projects/node_modules/x")
        XCTAssertEqual(discover(home)["project.node_modules"]?.map(\.name), ["Projects"])
    }

    func testNothingFoundWithoutRoots() throws {
        let home = try FakeHome()
        try home.makeFile("Projects/app/package.json")
        try home.makeFile("Projects/app/node_modules/x")
        XCTAssertTrue(ProjectScanner.discover(guard: ArtifactGuard(home: home.url, roots: [])).isEmpty)
    }

    func testActivityIgnoresArtifactsButSeesSourceEdits() throws {
        let home = try FakeHome()
        let project = home.path("Projects/app")
        let manifest = try home.makeFile("Projects/app/package.json")
        let source = try home.makeFile("Projects/app/src/main.js")
        let installed = try home.makeFile("Projects/app/node_modules/dep/index.js")
        for url in [manifest, source] { try setModified(url, daysAgo: 100) }
        try setModified(home.path("Projects/app/src"), daysAgo: 100)
        try setModified(project, daysAgo: 100)

        // Свіжа установка залежностей не робить проєкт «активним».
        try setModified(installed, daysAgo: 1)
        var age = try XCTUnwrap(ProjectActivity.newest(in: project, home: home.url)).timeIntervalSinceNow / -86_400
        XCTAssertGreaterThan(age, 99)

        // А правка коду робить.
        try setModified(source, daysAgo: 2)
        age = try XCTUnwrap(ProjectActivity.newest(in: project, home: home.url)).timeIntervalSinceNow / -86_400
        XCTAssertLessThan(age, 3)
    }

    func testActivityUsesGitSignals() throws {
        let home = try FakeHome()
        let project = home.path("Projects/app")
        let manifest = try home.makeFile("Projects/app/package.json")
        try home.makeFile("Projects/app/.git/HEAD")
        let index = try home.makeFile("Projects/app/.git/index")
        try setModified(manifest, daysAgo: 200)
        try setModified(home.path("Projects/app/.git/HEAD"), daysAgo: 200)
        try setModified(home.path("Projects/app/.git"), daysAgo: 200)
        try setModified(project, daysAgo: 200)
        try setModified(index, daysAgo: 4)
        let age = try XCTUnwrap(ProjectActivity.newest(in: project, home: home.url)).timeIntervalSinceNow / -86_400
        XCTAssertLessThan(age, 5)
    }
}

final class DefaultSelectionTests: CleanerTestCase {
    private func entry(daysAgo: Double?) -> Entry {
        var entry = Entry(ruleID: "r", url: URL(fileURLWithPath: "/tmp/x"))
        entry.measurement = DiskUsage(
            bytes: 10, fileCount: 1, lastModified: daysAgo.map { Date().addingTimeInterval(-$0 * 86_400) }, hadErrors: false
        )
        return entry
    }

    func testSafeSelectedCarefulNot() throws {
        XCTAssertTrue(DiskScanner.isSelectedByDefault(entry(daysAgo: 1), rule: try makeRule(paths: ["~/a/b"])))
        let careful = try JSONDecoder().decode(CleanupRule.self, from: Data(
            #"{"id":"c","group":"g","title":"T","detail":"D","risk":"careful","paths":["~/a/b"]}"#.utf8))
        XCTAssertFalse(DiskScanner.isSelectedByDefault(entry(daysAgo: 500), rule: careful))
    }

    func testOlderThanThresholdDecidesForProjects() throws {
        let rule = try makeRule(paths: ["~/a/b"], extra: "\"autoSelectOlderThanDays\":30")
        XCTAssertFalse(DiskScanner.isSelectedByDefault(entry(daysAgo: 10), rule: rule))
        XCTAssertFalse(DiskScanner.isSelectedByDefault(entry(daysAgo: 29), rule: rule))
        XCTAssertTrue(DiskScanner.isSelectedByDefault(entry(daysAgo: 31), rule: rule))
        XCTAssertFalse(DiskScanner.isSelectedByDefault(entry(daysAgo: nil), rule: rule), "невідома дата не вибирається")
    }

    func testAdminRulesNeverSelectedByDefault() throws {
        let rule = try makeRule(paths: ["/Library/Caches"], extra: "\"requiresAdmin\":true")
        XCTAssertFalse(DiskScanner.isSelectedByDefault(entry(daysAgo: 500), rule: rule))
    }

    func testProjectKindsDefaults() {
        for kind in ArtifactKind.all where kind.id != "project.venv" {
            XCTAssertEqual(kind.rule.autoSelectOlderThanDays, 30, kind.id)
        }
        XCTAssertNil(ArtifactKind.all.first { $0.id == "project.venv" }?.rule.autoSelectOlderThanDays)
        XCTAssertEqual(ArtifactKind.all.first { $0.id == "project.venv" }?.rule.risk, .careful)
    }
}
