import Foundation

// MARK: - Regular commands (xcrun simctl)

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

/// Collects stdout/stderr from two streams without blocking on a full pipe.
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

// MARK: - Commands with administrator rights

public enum PrivilegedOutcome: Sendable, Equatable {
    /// The command finished without errors.
    case finished
    /// The user pressed "Cancel" in the password prompt.
    case cancelled
    case failed(String)
}

public protocol PrivilegedRunner: Sendable {
    /// Deletes paths with administrator rights. The engine has already validated every path (`SystemPathGuard` for
    /// system folders, `ApplicationGuard` for apps), and the runner checks them again right before the command.
    func removeItems(_ paths: [String], prompt: String) -> PrivilegedOutcome
}

public enum AppleScript {
    /// Escapes a string for the shell in single quotes: `it's` → `'it'\''s'`.
    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a string for an AppleScript literal in double quotes.
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

/// Shows the system administrator password prompt (like Onyx) and deletes paths via `rm`.
public struct AppleScriptPrivilegedRunner: PrivilegedRunner {
    private let runner: CommandRunner
    private let applicationRoots: [String]

    public init(runner: CommandRunner = ProcessRunner(), home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.runner = runner
        applicationRoots = ["/Applications", home.standardizedFileURL.appendingPathComponent("Applications").path]
    }

    /// The last check right before the command with administrator rights: the engine has already validated the paths,
    /// but time can pass between that and the password prompt, and `rm -rf` as root must not run on anything
    /// other than what is allowed. Allowed only: the contents of `/Library/Caches` and `/Library/Logs`
    /// (as in `SystemPathGuard`) and `.app` folders directly inside `/Applications` or `~/Applications`.
    /// The path must be absolute, contain no `..`, and must not be a symlink in these `.app` folders.
    func isAllowed(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard path.hasPrefix("/"), url.standardizedFileURL.path == path else { return false }
        if (try? SystemPathGuard().validate(url)) != nil { return true }
        var st = stat()
        return url.pathExtension == "app"
            && applicationRoots.contains(url.deletingLastPathComponent().path)
            && lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    public func removeItems(_ paths: [String], prompt: String) -> PrivilegedOutcome {
        guard !paths.isEmpty else { return .finished }
        if let refused = paths.first(where: { !isAllowed($0) }) {
            return .failed(L("Refusing to delete with administrator rights: %@", refused))
        }
        let script = AppleScript.doShellScript(command: AppleScript.removeCommand(for: paths), prompt: prompt, admin: true)
        let result = runner.run("/usr/bin/osascript", ["-e", script])
        if result.status == 0 { return .finished }
        // Code -128 = the user cancelled the dialog (osascript prints "User canceled. (-128)").
        if result.error.contains("(-128)") || result.error.localizedCaseInsensitiveContains("User canceled") {
            return .cancelled
        }
        return .failed(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Trash

public protocol Trasher: Sendable {
    func trash(_ url: URL) throws
}

/// Moves to the real Trash (can be restored via "Put Back").
public struct SystemTrasher: Trasher {
    public init() {}

    public func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
