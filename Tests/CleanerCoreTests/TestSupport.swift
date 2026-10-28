import Foundation
import XCTest
@testable import CleanerCore

/// Підроблена домашня папка у temp, щоб тести ніколи не торкались справжньої.
final class FakeHome {
    let url: URL

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        url = base.appendingPathComponent("cleaner-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        // Права могли бути знято тестом.
        _ = try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func makeFile(_ relative: String, bytes: Int = 8192) throws -> URL {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: file)
        return file
    }

    func path(_ relative: String) -> URL { url.appendingPathComponent(relative) }
    func exists(_ relative: String) -> Bool {
        var st = stat()
        return lstat(path(relative).path, &st) == 0
    }
}

func makeRule(
    id: String = "test.rule", paths: [String], granularity: String = "children",
    extra: String = ""
) throws -> CleanupRule {
    let pathList = paths.map { "\"\($0)\"" }.joined(separator: ",")
    let json = """
    {"id":"\(id)","group":"g","title":"T","detail":"D","risk":"safe","paths":[\(pathList)],
     "granularity":"\(granularity)"\(extra.isEmpty ? "" : "," + extra)}
    """
    return try JSONDecoder().decode(CleanupRule.self, from: Data(json.utf8))
}

func makeRuleSet(_ rules: [CleanupRule]) -> RuleSet {
    RuleSet(groups: [CleanupGroup(id: "g", title: "G", symbol: "gear")], rules: rules)
}

/// Підроблений запуск команд: запам'ятовує виклики й віддає наперед задані відповіді.
final class FakeRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var responses: [String: CommandResult] = [:]
    var defaultResult = CommandResult(status: 0)

    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        recorded.append([executable] + arguments)
        return responses[arguments.joined(separator: " ")] ?? defaultResult
    }
}

/// Підроблений «адмін»: нічого не питає, а справжні файли видаляє сам (у тестах це temp-папка).
final class FakePrivileged: PrivilegedRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var outcome: PrivilegedOutcome = .finished
    var actuallyDelete = true

    var receivedBatches: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func removeItems(_ paths: [String], prompt: String) -> PrivilegedOutcome {
        lock.lock()
        recorded.append(paths)
        let outcome = self.outcome, delete = actuallyDelete
        lock.unlock()
        if outcome == .finished, delete {
            for path in paths { try? FileManager.default.removeItem(atPath: path) }
        }
        return outcome
    }
}

func setModified(_ url: URL, daysAgo: Double) throws {
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url.path
    )
}

/// Підроблений Кошик: переносить у temp-папку, а не в справжній Кошик користувача.
final class FakeTrasher: Trasher, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let directory: URL
    var failing: Set<String> = []

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var trashedPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func trash(_ url: URL) throws {
        if failing.contains(url.path) { throw NSError(domain: "FakeTrasher", code: 1, userInfo: [NSLocalizedDescriptionKey: "не вдалося"]) }
        let target = directory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: target)
        lock.lock(); recorded.append(url.path); lock.unlock()
    }
}

func makeEngine(
    _ home: FakeHome, projectRoots: [URL] = [], fileRoots: [URL] = [], applicationRoots: [URL]? = nil,
    systemRoots: [String] = SystemPathGuard.defaultRoots,
    runner: CommandRunner = FakeRunner(), privileged: PrivilegedRunner = FakePrivileged(), trasher: Trasher? = nil
) -> CleanEngine {
    CleanEngine(
        safety: SafetyPolicy(
            home: home.url, projectRoots: projectRoots, fileRoots: fileRoots,
            systemRoots: systemRoots, applicationRoots: applicationRoots),
        runner: runner, privileged: privileged,
        trasher: trasher ?? FakeTrasher(directory: home.path("fake-trash")),
        logDirectory: home.path("logs")
    )
}

/// Мінімальний `.app` з Info.plist.
@discardableResult
func makeApp(_ home: FakeHome, at relative: String, bundleID: String, name: String, version: String = "1.0") throws -> URL {
    let app = home.path(relative)
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundleShortVersionString": version,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
    try Data(repeating: 0x42, count: 20_000).write(to: app.appendingPathComponent("Contents/MacOS/\(name)"))
    return app
}
