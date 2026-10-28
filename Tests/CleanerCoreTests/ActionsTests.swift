import XCTest
@testable import CleanerCore

final class SimulatorProviderTests: XCTestCase {
    private let devicesJSON = """
    {"devices":{
      "com.apple.CoreSimulator.SimRuntime.iOS-17-5":[
        {"lastBootedAt":"2026-10-27T15:37:41Z","dataPath":"/Users/u/Library/Developer/CoreSimulator/Devices/C950F996-4117-4F5A-8F0E-6B70A043F8A3/data",
         "dataPathSize":481943552,"udid":"C950F996-4117-4F5A-8F0E-6B70A043F8A3","isAvailable":true,"state":"Shutdown","name":"iPhone 15 Pro"},
        {"dataPath":"/Users/u/Library/Developer/CoreSimulator/Devices/B379A94A-0000-4000-8000-000000000001/data",
         "udid":"B379A94A-0000-4000-8000-000000000001","isAvailable":true,"state":"Booted","name":"iPhone 15"}
      ],
      "com.apple.CoreSimulator.SimRuntime.watchOS-10-0":[
        {"udid":"E15BE9D3-0000-4000-8000-000000000002","isAvailable":false,"state":"Shutdown","name":"Apple Watch"}
      ]}}
    """

    func testParsesDevices() throws {
        let home = URL(fileURLWithPath: "/Users/u")
        let entries = SimulatorProvider.parseDevices(Data(devicesJSON.utf8), ruleID: "sim", home: home)
        XCTAssertEqual(entries.count, 3)

        let pro = try XCTUnwrap(entries.first { $0.name == "iPhone 15 Pro" })
        XCTAssertEqual(pro.action, .simctlDeleteDevice(udid: "C950F996-4117-4F5A-8F0E-6B70A043F8A3"))
        XCTAssertEqual(pro.url.lastPathComponent, "C950F996-4117-4F5A-8F0E-6B70A043F8A3", "видаляємо весь пристрій, а не папку data")
        XCTAssertEqual(pro.subtitle, "iOS 17.5")
        XCTAssertEqual(pro.presetUsage?.bytes, 481_943_552)
        XCTAssertNotNil(pro.presetUsage?.lastModified)
        XCTAssertNil(pro.lockedReason)

        XCTAssertNotNil(entries.first { $0.name == "iPhone 15" }?.lockedReason, "запущений симулятор заблоковано")
        let watch = try XCTUnwrap(entries.first { $0.name == "Apple Watch" })
        XCTAssertTrue(try XCTUnwrap(watch.subtitle).contains("watchOS 10.0"))
        XCTAssertTrue(try XCTUnwrap(watch.subtitle).contains("недоступний"))
        XCTAssertEqual(watch.url.path, "/Users/u/Library/Developer/CoreSimulator/Devices/E15BE9D3-0000-4000-8000-000000000002")
    }

    func testGarbageJSONGivesNoEntries() {
        XCTAssertTrue(SimulatorProvider.parseDevices(Data("nope".utf8), ruleID: "x", home: URL(fileURLWithPath: "/")).isEmpty)
        XCTAssertTrue(SimulatorProvider.parseRuntimes(Data("[]".utf8), ruleID: "x").isEmpty)
    }

    func testParsesRuntimesAndFlagsOlderBuild() throws {
        let json = """
        {"AAAAAAAA-0000-4000-8000-000000000001":{"build":"21A328","deletable":true,"identifier":"AAAAAAAA-0000-4000-8000-000000000001",
          "kind":"Disk Image","lastUsedAt":"2023-01-01T00:00:00Z","path":"/Library/Developer/CoreSimulator/Images/a.dmg",
          "runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-17-0","sizeBytes":7560000000,"state":"Ready","version":"17.0"},
         "BBBBBBBB-0000-4000-8000-000000000002":{"build":"21A342","deletable":true,"identifier":"BBBBBBBB-0000-4000-8000-000000000002",
          "kind":"Disk Image","path":"/Library/Developer/CoreSimulator/Images/b.dmg",
          "runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-17-0","sizeBytes":7210000000,"state":"Ready","version":"17.0.1"},
         "CCCCCCCC-0000-4000-8000-000000000003":{"build":"1","deletable":false,"identifier":"CCCCCCCC-0000-4000-8000-000000000003",
          "kind":"Bundled","path":"","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.tvOS-18-0","sizeBytes":5,"state":"Ready","version":"18.0"}}
        """
        let entries = SimulatorProvider.parseRuntimes(Data(json.utf8), ruleID: "rt")
        XCTAssertEqual(entries.count, 3)

        let old = try XCTUnwrap(entries.first { $0.name == "iOS 17.0 (21A328)" })
        XCTAssertEqual(old.action, .simctlDeleteRuntime(id: "AAAAAAAA-0000-4000-8000-000000000001"))
        XCTAssertEqual(old.presetUsage?.bytes, 7_560_000_000)
        XCTAssertTrue(try XCTUnwrap(old.subtitle).contains("17.0.1"), "старішу збірку позначено")
        XCTAssertNil(entries.first { $0.name == "iOS 17.0.1 (21A342)" }?.subtitle, "новішу не позначаємо")
        XCTAssertNotNil(entries.first { $0.name.hasPrefix("tvOS") }?.lockedReason, "недоступне для видалення заблоковано")
    }
}

final class AppleScriptTests: XCTestCase {
    func testShellQuoteHandlesSingleQuotes() {
        XCTAssertEqual(AppleScript.shellQuote("plain"), "'plain'")
        XCTAssertEqual(AppleScript.shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(AppleScript.removeCommand(for: ["/a b/c", "/x'y"]), "/bin/rm -rf -- '/a b/c' '/x'\\''y'")
    }

    /// Справжній прогін через osascript (без прав адміна): рядок має дійти до shell без змін.
    func testQuotingSurvivesAppleScriptAndShell() {
        let nasty = "it's a \"test\" \\ with $HOME `cmd` ; & * spaces ü"
        let script = AppleScript.doShellScript(command: "printf '%s' " + AppleScript.shellQuote(nasty), prompt: nil, admin: false)
        let result = ProcessRunner().run("/usr/bin/osascript", ["-e", script])
        XCTAssertEqual(result.status, 0, result.error)
        XCTAssertEqual(result.output.trimmingCharacters(in: .newlines), nasty)
    }

    func testAdminScriptCompiles() throws {
        let script = AppleScript.doShellScript(
            command: AppleScript.removeCommand(for: ["/Library/Caches/it's \"x\""]), prompt: "Введи \"пароль\"", admin: true
        )
        XCTAssertTrue(script.hasSuffix("with administrator privileges"))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).scpt")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = ProcessRunner().run("/usr/bin/osacompile", ["-o", output.path, "-e", script])
        XCTAssertEqual(result.status, 0, result.error)
    }

    func testPrivilegedRunnerMapsOutcomes() {
        let fake = FakeRunner()
        let runner = AppleScriptPrivilegedRunner(runner: fake)

        XCTAssertEqual(runner.removeItems(["/Library/Caches/a"], prompt: "p"), .finished)
        XCTAssertEqual(fake.calls.first?.first, "/usr/bin/osascript")
        XCTAssertTrue(fake.calls.first?.last?.contains("with administrator privileges") == true)

        fake.defaultResult = CommandResult(status: 1, error: "execution error: User canceled. (-128)")
        XCTAssertEqual(runner.removeItems(["/Library/Caches/a"], prompt: "p"), .cancelled)

        fake.defaultResult = CommandResult(status: 1, error: "rm: Operation not permitted")
        XCTAssertEqual(runner.removeItems(["/Library/Caches/a"], prompt: "p"), .failed("rm: Operation not permitted"))

        XCTAssertEqual(runner.removeItems([], prompt: "p"), .finished)
    }
}

final class EngineActionTests: XCTestCase {
    private let udid = "C950F996-4117-4F5A-8F0E-6B70A043F8A3"

    private func simRule() -> CleanupRule {
        CleanupRule(id: "sim", group: "g", title: "T", detail: "D", risk: .careful, provider: "simctl.devices")
    }

    private func simEntry(udid: String, locked: String? = nil, bytes: Int64 = 1_000) -> Entry {
        var entry = Entry(
            ruleID: "sim", url: URL(fileURLWithPath: "/tmp/sim-\(udid)"), name: "iPhone", lockedReason: locked,
            action: .simctlDeleteDevice(udid: udid)
        )
        entry.measurement = DiskUsage(bytes: bytes, fileCount: 0, lastModified: nil, hadErrors: false)
        return entry
    }

    func testSimctlDeleteRunsNativeCommand() throws {
        let home = try FakeHome()
        let runner = FakeRunner()
        let report = makeEngine(home, runner: runner).clean(entries: [simEntry(udid: udid)], rules: [simRule()], dryRun: false)
        XCTAssertEqual(runner.calls, [["/usr/bin/xcrun", "simctl", "delete", udid]])
        XCTAssertEqual(report.freedBytes, 1_000)
        XCTAssertTrue(report.failures.isEmpty)
    }

    func testSimctlRuntimeDeleteCommand() throws {
        let home = try FakeHome()
        let runner = FakeRunner()
        var entry = Entry(
            ruleID: "rt", url: URL(fileURLWithPath: "/tmp/r.dmg"), id: "simruntime:\(udid)", name: "iOS 17.0",
            action: .simctlDeleteRuntime(id: udid)
        )
        entry.measurement = DiskUsage(bytes: 7_000, fileCount: 0, lastModified: nil, hadErrors: false)
        let rule = CleanupRule(id: "rt", group: "g", title: "T", detail: "D", risk: .careful, provider: "simctl.runtimes")
        let report = makeEngine(home, runner: runner).clean(entries: [entry], rules: [rule], dryRun: false)
        XCTAssertEqual(runner.calls, [["/usr/bin/xcrun", "simctl", "runtime", "delete", udid]])
        XCTAssertEqual(report.freedBytes, 7_000)
    }

    func testSimctlFailureIsReportedWithMessage() throws {
        let home = try FakeHome()
        let runner = FakeRunner()
        runner.defaultResult = CommandResult(status: 1, error: "Unable to delete device")
        let report = makeEngine(home, runner: runner).clean(entries: [simEntry(udid: udid)], rules: [simRule()], dryRun: false)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.freedBytes, 0)
        guard case .failed(let message) = report.failures[0].outcome else { return XCTFail() }
        XCTAssertEqual(message, "Unable to delete device")
    }

    func testSimctlDryRunBadIdentifierAndLockedNeverRunCommands() throws {
        let home = try FakeHome()
        let runner = FakeRunner()
        let engine = makeEngine(home, runner: runner)

        let dry = engine.clean(entries: [simEntry(udid: udid)], rules: [simRule()], dryRun: true)
        XCTAssertEqual(dry.freedBytes, 1_000)

        let hostile = simEntry(udid: "x; rm -rf ~")
        let locked = simEntry(udid: udid, locked: "Симулятор запущений")
        let report = engine.clean(entries: [hostile, locked], rules: [simRule()], dryRun: false)
        XCTAssertEqual(report.skipped.count, 2)
        XCTAssertTrue(runner.calls.isEmpty, "жодної команди: \(runner.calls)")
    }

    // MARK: Адмін

    private func adminSetup() throws -> (FakeHome, CleanupRule, SafetyPolicy, [Entry]) {
        let home = try FakeHome()
        try home.makeFile("sys/Caches/com.vendor.app/data.bin", bytes: 20_000)
        try home.makeFile("sys/Caches/other/data.bin", bytes: 20_000)
        let root = home.path("sys/Caches").path
        let rule = try makeRule(id: "sys", paths: [root], extra: "\"requiresAdmin\":true")
        let scanner = DiskScanner(ruleSet: makeRuleSet([rule]), home: home.url, systemRoots: [root])
        var entries = scanner.discover()[0].entries
        for index in entries.indices { entries[index].measurement = DiskSize.measure(entries[index].url) }
        return (home, rule, scanner.safety, entries)
    }

    func testAdminEntriesAreDiscoveredWithSystemScope() throws {
        let (_, _, _, entries) = try adminSetup()
        XCTAssertEqual(entries.map(\.name).sorted(), ["com.vendor.app", "other"])
        XCTAssertTrue(entries.allSatisfy { $0.scope == .system })
    }

    func testAdminBatchGoesToPrivilegedRunnerOnce() throws {
        let (home, rule, _, entries) = try adminSetup()
        let privileged = FakePrivileged()
        let engine = makeEngine(home, systemRoots: [home.path("sys/Caches").path], privileged: privileged)
        let report = engine.clean(entries: entries, rules: [rule], dryRun: false)

        XCTAssertEqual(privileged.receivedBatches.count, 1, "один запит пароля на все")
        XCTAssertEqual(Set(privileged.receivedBatches[0]), Set(entries.map(\.url.path)))
        XCTAssertFalse(home.exists("sys/Caches/com.vendor.app"))
        XCTAssertTrue(home.exists("sys/Caches"), "сам корінь лишається")
        XCTAssertGreaterThanOrEqual(report.freedBytes, 40_000)
        XCTAssertTrue(report.failures.isEmpty)
    }

    func testAdminDryRunNeverAsksForPassword() throws {
        let (home, rule, _, entries) = try adminSetup()
        let privileged = FakePrivileged()
        let report = makeEngine(home, systemRoots: [home.path("sys/Caches").path], privileged: privileged)
            .clean(entries: entries, rules: [rule], dryRun: true)
        XCTAssertTrue(privileged.receivedBatches.isEmpty)
        XCTAssertTrue(home.exists("sys/Caches/com.vendor.app"))
        XCTAssertGreaterThan(report.freedBytes, 0)
    }

    func testCancelledPasswordSkipsAndKeepsFiles() throws {
        let (home, rule, _, entries) = try adminSetup()
        let privileged = FakePrivileged()
        privileged.outcome = .cancelled
        let report = makeEngine(home, systemRoots: [home.path("sys/Caches").path], privileged: privileged)
            .clean(entries: entries, rules: [rule], dryRun: false)
        XCTAssertEqual(report.skipped.count, 2)
        XCTAssertEqual(report.freedBytes, 0)
        XCTAssertTrue(home.exists("sys/Caches/com.vendor.app"))
    }

    func testForgedSystemEntriesNeverReachPrivilegedRunner() throws {
        let (home, rule, _, _) = try adminSetup()
        let privileged = FakePrivileged()
        func forged(_ path: String) -> Entry {
            var entry = Entry(ruleID: rule.id, url: URL(fileURLWithPath: path), scope: .system)
            entry.measurement = DiskUsage(bytes: 1, fileCount: 1, lastModified: nil, hadErrors: false)
            return entry
        }
        let engine = makeEngine(home, systemRoots: [home.path("sys/Caches").path], privileged: privileged)
        let report = engine.clean(
            entries: [forged("/etc/hosts"), forged("/System/Library"), forged(home.path("sys").path), forged(home.path("sys/Caches").path)],
            rules: [rule], dryRun: false
        )
        XCTAssertEqual(report.skipped.count, 4)
        XCTAssertTrue(privileged.receivedBatches.isEmpty)
    }

    func testScopeMustMatchRule() throws {
        let home = try FakeHome()
        try home.makeFile("sys/Caches/x/data")
        let root = home.path("sys/Caches").path
        let plainRule = try makeRule(id: "plain", paths: ["~/whatever"])
        var entry = Entry(ruleID: "plain", url: home.path("sys/Caches/x"), scope: .system)
        entry.measurement = DiskUsage(bytes: 1, fileCount: 1, lastModified: nil, hadErrors: false)
        let privileged = FakePrivileged()
        let report = makeEngine(home, systemRoots: [root], privileged: privileged).clean(entries: [entry], rules: [plainRule], dryRun: false)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertTrue(privileged.receivedBatches.isEmpty)
    }

    // MARK: AVD і проєкти

    func testAvdIsRemovedTogetherWithItsIni() throws {
        let home = try FakeHome()
        try home.makeFile(".android/avd/Pixel_8.avd/userdata.img", bytes: 40_000)
        try home.makeFile(".android/avd/Pixel_8.ini", bytes: 200)
        try home.makeFile(".android/avd/Orphan.ini", bytes: 200)
        let rule = try makeRule(
            id: "avd", paths: ["~/.android/avd"],
            extra: "\"includeNames\":[\"*.avd\"],\"companions\":[\"{base}.ini\"]"
        )
        let scanner = DiskScanner(ruleSet: makeRuleSet([rule]), home: home.url)
        var entries = scanner.discover()[0].entries
        XCTAssertEqual(entries.map(\.name), ["Pixel_8"], "лише .avd, ім'я без розширення")
        XCTAssertEqual(entries[0].companions.map(\.lastPathComponent), ["Pixel_8.ini"])

        entries[0].measurement = DiskUsage(bytes: 40_000, fileCount: 1, lastModified: nil, hadErrors: false)
        let report = makeEngine(home).clean(entries: entries, rules: [rule], dryRun: false)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(home.exists(".android/avd/Pixel_8.avd"))
        XCTAssertFalse(home.exists(".android/avd/Pixel_8.ini"))
        XCTAssertTrue(home.exists(".android/avd/Orphan.ini"), "чужі файли не чіпаємо")
    }

    func testProjectArtifactsInsideDocumentsAreRemovedButNothingElse() throws {
        let home = try FakeHome()
        try home.makeFile("Documents/Projects/app/package.json")
        try home.makeFile("Documents/Projects/app/src/main.js")
        try home.makeFile("Documents/Projects/app/node_modules/dep/index.js", bytes: 30_000)
        let roots = [home.path("Documents/Projects")]
        let guardian = ArtifactGuard(home: home.url, roots: roots)
        var entries = ProjectScanner.discover(guard: guardian).flatMap(\.entries)
        XCTAssertEqual(entries.count, 1)
        entries[0].measurement = DiskUsage(bytes: 30_000, fileCount: 1, lastModified: nil, hadErrors: false)

        // Той самий елемент без дозволеної папки проєктів рушій відхиляє: Documents захищено.
        let denied = makeEngine(home).clean(entries: entries, rules: ArtifactKind.all.map(\.rule), dryRun: false)
        XCTAssertEqual(denied.skipped.count, 1)
        XCTAssertTrue(home.exists("Documents/Projects/app/node_modules"))

        let report = makeEngine(home, projectRoots: roots).clean(entries: entries, rules: ArtifactKind.all.map(\.rule), dryRun: false)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(home.exists("Documents/Projects/app/node_modules"))
        XCTAssertTrue(home.exists("Documents/Projects/app/package.json"), "код проєкту лишається")
        XCTAssertTrue(home.exists("Documents/Projects/app/src/main.js"))
    }

    func testForgedProjectEntriesAreRejected() throws {
        let home = try FakeHome()
        try home.makeFile("Documents/Projects/app/package.json")
        try home.makeFile("Documents/Projects/app/src/main.js")
        try home.makeFile("Documents/thesis/node_modules/x")
        let roots = [home.path("Documents/Projects")]
        func forged(_ relative: String) -> Entry {
            var entry = Entry(ruleID: "project.node_modules", url: home.path(relative), scope: .project)
            entry.measurement = DiskUsage(bytes: 1, fileCount: 1, lastModified: nil, hadErrors: false)
            return entry
        }
        let report = makeEngine(home, projectRoots: roots).clean(
            entries: [forged("Documents/Projects/app/src"), forged("Documents/Projects/app"), forged("Documents/thesis/node_modules"), forged("Documents")],
            rules: ArtifactKind.all.map(\.rule), dryRun: false
        )
        XCTAssertEqual(report.skipped.count, 4)
        XCTAssertTrue(home.exists("Documents/Projects/app/src/main.js"))
        XCTAssertTrue(home.exists("Documents/thesis/node_modules/x"))
    }
}
