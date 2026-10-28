import Foundation

// MARK: - Звичайні команди (xcrun simctl)

public struct CommandResult: Sendable, Equatable {
    public let status: Int32
    public let output: String
    public let error: String

    public init(status: Int32, output: String = "", error: String = "") {
        self.status = status
        self.output = output
        self.error = error
    }
}

public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) -> CommandResult
}

/// Збирає stdout/stderr з двох потоків, не блокуючись на повному pipe.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ newData: Data) {
        lock.lock(); data = newData; lock.unlock()
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct ProcessRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let errorCollector = OutputCollector()
        let group = DispatchGroup()
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, error: error.localizedDescription)
        }
        group.enter()
        DispatchQueue.global().async {
            errorCollector.store(err.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        let outputData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        return CommandResult(status: process.terminationStatus, output: String(decoding: outputData, as: UTF8.self), error: errorCollector.text)
    }
}

// MARK: - Команди з правами адміна

public enum PrivilegedOutcome: Sendable, Equatable {
    /// Команда виконалась без помилок.
    case finished
    /// Користувач натиснув «Скасувати» в запиті пароля.
    case cancelled
    case failed(String)
}

public protocol PrivilegedRunner: Sendable {
    /// Видаляє шляхи з правами адміна. Усі шляхи вже перевірені `SystemPathGuard`.
    func removeItems(_ paths: [String], prompt: String) -> PrivilegedOutcome
}

public enum AppleScript {
    /// Екранує рядок для shell у одинарних лапках: `it's` → `'it'\''s'`.
    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Екранує рядок для літерала AppleScript у подвійних лапках.
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    public static func doShellScript(command: String, prompt: String?, admin: Bool) -> String {
        var script = "do shell script \"\(escape(command))\""
        if let prompt { script += " with prompt \"\(escape(prompt))\"" }
        if admin { script += " with administrator privileges" }
        return script
    }

    static func removeCommand(for paths: [String]) -> String {
        "/bin/rm -rf -- " + paths.map(shellQuote).joined(separator: " ")
    }
}

/// Показує системний запит пароля адміна (як Onyx) і видаляє шляхи через `rm`.
public struct AppleScriptPrivilegedRunner: PrivilegedRunner {
    private let runner: CommandRunner

    public init(runner: CommandRunner = ProcessRunner()) {
        self.runner = runner
    }

    public func removeItems(_ paths: [String], prompt: String) -> PrivilegedOutcome {
        guard !paths.isEmpty else { return .finished }
        let script = AppleScript.doShellScript(command: AppleScript.removeCommand(for: paths), prompt: prompt, admin: true)
        let result = runner.run("/usr/bin/osascript", ["-e", script])
        if result.status == 0 { return .finished }
        // Код -128 = користувач скасував діалог.
        if result.error.contains("-128") || result.error.localizedCaseInsensitiveContains("User canceled") {
            return .cancelled
        }
        return .failed(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Кошик

public protocol Trasher: Sendable {
    func trash(_ url: URL) throws
}

/// Переміщує в справжній Кошик (можна повернути через «Покласти назад»).
public struct SystemTrasher: Trasher {
    public init() {}

    public func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
