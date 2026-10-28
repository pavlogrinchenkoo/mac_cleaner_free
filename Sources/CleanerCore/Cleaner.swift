import Darwin
import Foundation

public struct CleanItemResult: Sendable, Identifiable {
    public enum Outcome: Sendable {
        /// Removed completely.
        case removed
        /// Moved to the Trash: the space is freed once the Trash is emptied.
        case trashed
        /// Dry run: nothing was changed.
        case dryRun
        /// Skipped with a reason (gone, blocked, failed validation, cancelled).
        case skipped(String)
        /// Failure; `bytes` is how much had been freed before it.
        case failed(String)
    }

    /// What would be / was done: permanent deletion or the Trash.
    public enum Disposal: Sendable { case delete, trash }

    public let id: String
    public let path: String
    public let outcome: Outcome
    public let disposal: Disposal
    /// How much space was affected (for `dryRun`: how much would be).
    public let bytes: Int64
    /// A warning that does not change the outcome (for example, a leftover could not be moved).
    public let note: String?

    public init(id: String, path: String, outcome: Outcome, disposal: Disposal = .delete, bytes: Int64, note: String? = nil) {
        self.id = id
        self.path = path
        self.outcome = outcome
        self.disposal = disposal
        self.bytes = bytes
        self.note = note
    }
}

public struct CleanReport: Sendable {
    public var items: [CleanItemResult]
    public var dryRun: Bool
    public var logURL: URL?

    /// Space that was (or would be) freed by permanent deletion.
    public var freedBytes: Int64 {
        items.filter { $0.disposal == .delete }.reduce(0) { $0 + $1.bytes }
    }
    /// What was (or would be) moved to the Trash: the space is freed once it is emptied.
    public var trashedBytes: Int64 {
        items.filter { $0.disposal == .trash }.reduce(0) { $0 + $1.bytes }
    }
    public var failures: [CleanItemResult] {
        items.filter { if case .failed = $0.outcome { true } else { false } }
    }
    public var skipped: [CleanItemResult] {
        items.filter { if case .skipped = $0.outcome { true } else { false } }
    }
}

/// Deletes the selected items. Re-checks safety before every action.
public final class CleanEngine: Sendable {
    private let safety: SafetyPolicy
    private let runner: CommandRunner
    private let privileged: PrivilegedRunner
    private let trasher: Trasher
    private let logDirectory: URL

    public init(
        safety: SafetyPolicy,
        runner: CommandRunner = ProcessRunner(),
        privileged: PrivilegedRunner = AppleScriptPrivilegedRunner(),
        trasher: Trasher = SystemTrasher(),
        logDirectory: URL? = nil
    ) {
        self.safety = safety
        self.runner = runner
        self.privileged = privileged
        self.trasher = trasher
        self.logDirectory = logDirectory
            ?? safety.home.home.appendingPathComponent("Library/Application Support/Cleaner/logs")
    }

    /// Synchronous and long-running: call it from a background thread/Task.
    public func clean(
        entries: [Entry],
        rules: [CleanupRule],
        dryRun: Bool,
        progress: @Sendable (_ done: Int, _ total: Int, _ current: String) -> Void = { _, _, _ in }
    ) -> CleanReport {
        let rulesByID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        // The snapshot of the running state is taken afresh right now, not during the scan.
        let snapshot = RunningSnapshot.current()
        let ruleBlocks = DiskScanner.ruleBlocks(for: rules, snapshot: snapshot)

        let homePath = safety.home.home.path
        var logLines: [String] = []
        var items: [CleanItemResult] = []
        let formatter = ISO8601DateFormatter()
        logLines.append("# Cleaner \(dryRun ? "DRY-RUN" : "CLEAN") \(formatter.string(from: Date()))")

        // Originals of duplicates that are being removed in this same batch: we do not touch them,
        // otherwise the last remaining version would vanish together with the copy.
        let keeperPaths = Set(entries.compactMap { $0.keeper?.path })

        // Actions that need the administrator password are collected into one batch:
        // a single password prompt for all of them.
        var adminCaches: [Entry] = []
        var adminApps: [Entry] = []

        for (index, entry) in entries.enumerated() {
            progress(index, entries.count, entry.name)
            let before = entry.bytes
            let disposal: CleanItemResult.Disposal = entry.action == .trashPaths ? .trash : .delete
            func finish(_ outcome: CleanItemResult.Outcome, _ bytes: Int64 = 0, note: String? = nil) {
                let result = CleanItemResult(id: entry.id, path: entry.id, outcome: outcome, disposal: disposal, bytes: bytes, note: note)
                items.append(result)
                logLines.append(Self.logLine(for: result, home: homePath))
            }

            do {
                try safety.validate(entry)
                if keeperPaths.contains(entry.url.path) {
                    throw CleanError.skipped(L("It is the original of a duplicate that is being removed"))
                }

                guard let rule = rulesByID[entry.ruleID] else { throw CleanError.skipped(L("Unknown rule")) }
                guard rule.requiresAdmin == (entry.scope == .system) else {
                    throw CleanError.skipped(L("Item type does not match the rule"))
                }
                if let reason = DiskScanner.blockReason(for: entry, rule: rule, ruleBlock: ruleBlocks[rule.id], snapshot: snapshot) {
                    throw CleanError.skipped(reason)
                }
                switch entry.action {
                case .removePaths, .trashPaths:
                    var st = stat()
                    guard lstat(entry.url.path, &st) == 0 else { throw CleanError.skipped(L("Already gone")) }
                case .simctlDeleteDevice, .simctlDeleteRuntime:
                    break
                }
                try verifyKeeper(entry, rule: rule)

                if dryRun {
                    finish(.dryRun, before)
                } else if entry.scope == .system {
                    adminCaches.append(entry)
                } else if entry.scope == .application && entry.needsAdmin {
                    adminApps.append(entry)
                } else {
                    perform(entry, before: before, finish: finish)
                }
            } catch let error as CleanError {
                finish(.skipped(error.message))
            } catch {
                finish(.skipped(error.localizedDescription))
            }
        }

        if !adminCaches.isEmpty || !adminApps.isEmpty {
            progress(entries.count, entries.count, L("Waiting for the administrator password…"))
            let paths = adminCaches.flatMap { [$0.url] + $0.companions }.map(\.path) + adminApps.map(\.url.path)
            let outcome = privileged.removeItems(paths, prompt: L("Cleaner deletes system files and apps. Enter your administrator password."))

            for entry in adminCaches {
                let result = adminResult(for: entry, outcome: outcome)
                items.append(result)
                logLines.append(Self.logLine(for: result, home: homePath))
            }
            for entry in adminApps {
                var result = adminResult(for: entry, outcome: outcome)
                // Leftovers (in ~/Library) belong to the user: we move them to the Trash only if the app is gone.
                if case .removed = result.outcome {
                    var failed: [String] = []
                    for url in entry.companions {
                        var st = stat()
                        guard lstat(url.path, &st) == 0 else { continue }
                        do { try trasher.trash(url) } catch { failed.append(url.lastPathComponent) }
                    }
                    if !failed.isEmpty {
                        result = CleanItemResult(
                            id: result.id, path: result.path, outcome: result.outcome, disposal: .delete, bytes: result.bytes,
                            note: L("Could not move the leftovers to the Trash: %@", failed.joined(separator: ", ")))
                    }
                }
                items.append(result)
                logLines.append(Self.logLine(for: result, home: homePath))
            }
        }
        progress(entries.count, entries.count, "")

        var report = CleanReport(items: items, dryRun: dryRun, logURL: nil)
        if !dryRun {
            logLines.append(L("# Freed: %lld bytes; in Trash: %lld bytes", report.freedBytes, report.trashedBytes))
            report.logURL = writeLog(logLines)
        }
        return report
    }

    /// Result for an item deleted in the batch that needed the password: we check whether it is really gone.
    private func adminResult(for entry: Entry, outcome: PrivilegedOutcome) -> CleanItemResult {
        var st = stat()
        let gone = lstat(entry.url.path, &st) != 0
        func result(_ outcome: CleanItemResult.Outcome, _ bytes: Int64) -> CleanItemResult {
            CleanItemResult(id: entry.id, path: entry.id, outcome: outcome, disposal: .delete, bytes: bytes)
        }
        switch outcome {
        case .cancelled where !gone:
            return result(.skipped(L("Password not entered")), 0)
        case _ where gone:
            return result(.removed, entry.bytes)
        case .failed(let message):
            let remaining = DiskSize.measure(entry.url).bytes
            return result(.failed(message.isEmpty ? L("Could not delete") : message), max(0, entry.bytes - remaining))
        default:
            // The command ran, but the item is still there: typically SIP, or the file is in use.
            let remaining = DiskSize.measure(entry.url).bytes
            return result(.failed(L("The system did not allow deletion")), max(0, entry.bytes - remaining))
        }
    }

    /// A copy may be removed only while the original is in place and unchanged.
    private func verifyKeeper(_ entry: Entry, rule: CleanupRule) throws {
        guard let keeper = entry.keeper else {
            if rule.id == FileScanner.duplicatesRule.id { throw CleanError.skipped(L("No original is set for the duplicate")) }
            return
        }
        var st = stat()
        guard keeper.path != entry.url.path, lstat(keeper.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              Int64(st.st_size) == keeper.size, TimeInterval(st.st_mtimespec.tv_sec) == keeper.modified
        else { throw CleanError.skipped(L("The original changed or is gone: leaving the copy alone")) }
    }

    /// Performs the action for an item that does not need administrator rights.
    private func perform(_ entry: Entry, before: Int64, finish: (CleanItemResult.Outcome, Int64, String?) -> Void) {
        switch entry.action {
        case .removePaths:
            do {
                for url in [entry.url] + entry.companions { try Self.remove(url) }
                finish(.removed, before, nil)
            } catch {
                // It may have been deleted partially: count how much was actually freed.
                let remaining = DiskSize.measure(entry.url).bytes
                finish(.failed(error.localizedDescription), max(0, before - remaining), nil)
            }
        case .trashPaths:
            do {
                // The main item first, then the leftovers: if the main item fails, the leftovers stay in place.
                try trasher.trash(entry.url)
            } catch {
                finish(.failed(error.localizedDescription), 0, nil)
                return
            }
            var failed: [String] = []
            for url in entry.companions {
                var st = stat()
                guard lstat(url.path, &st) == 0 else { continue }
                do { try trasher.trash(url) } catch { failed.append(url.lastPathComponent) }
            }
            finish(.trashed, before, failed.isEmpty ? nil : L("Could not move the leftovers to the Trash: %@", failed.joined(separator: ", ")))
        case .simctlDeleteDevice(let udid):
            report(runner.run(SimulatorProvider.xcrun, ["simctl", "delete", udid]), before: before, finish: finish)
        case .simctlDeleteRuntime(let id):
            report(runner.run(SimulatorProvider.xcrun, ["simctl", "runtime", "delete", id]), before: before, finish: finish)
        }
    }

    private func report(_ result: CommandResult, before: Int64, finish: (CleanItemResult.Outcome, Int64, String?) -> Void) {
        if result.status == 0 {
            finish(.removed, before, nil)
        } else {
            let message = (result.error.isEmpty ? result.output : result.error).trimmingCharacters(in: .whitespacesAndNewlines)
            finish(.failed(message.isEmpty ? L("simctl exited with code %ld", Int(result.status)) : message), 0, nil)
        }
    }

    private enum CleanError: Error {
        case skipped(String)
        var message: String {
            switch self { case .skipped(let text): text }
        }
    }

    /// If `url` is a symlink, `removeItem` removes the symlink itself, not what it points to.
    private static func remove(_ url: URL) throws {
        let fm = FileManager.default
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return }
        do {
            try fm.removeItem(at: url)
        } catch {
            // Typical cause: the tree contains folders without write permission (Gradle, Xcode).
            // Add the permission and retry.
            makeOwnerWritable(url)
            try fm.removeItem(at: url)
        }
    }

    private static func makeOwnerWritable(_ url: URL) {
        let cPath: UnsafeMutablePointer<CChar>? = strdup(url.path)
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
        defer { fts_close(stream) }
        while let ent = fts_read(stream) {
            guard Int32(ent.pointee.fts_info) == FTS_D, let st = ent.pointee.fts_statp?.pointee else { continue }
            chmod(ent.pointee.fts_path, st.st_mode | S_IRWXU)
        }
    }

    private static func logLine(for result: CleanItemResult, home: String) -> String {
        let path = result.path.hasPrefix(home + "/") ? "~" + result.path.dropFirst(home.count) : result.path
        let note = result.note.map { " [\($0)]" } ?? ""
        switch result.outcome {
        case .removed: return "REMOVED \(result.bytes) \(path)\(note)"
        case .trashed: return "TRASHED \(result.bytes) \(path)\(note)"
        case .dryRun: return "WOULD-\(result.disposal == .trash ? "TRASH" : "REMOVE") \(result.bytes) \(path)"
        case .skipped(let reason): return "SKIPPED (\(reason)) \(path)"
        case .failed(let message): return "FAILED (\(message)) freed=\(result.bytes) \(path)"
        }
    }

    private func writeLog(_ lines: [String]) -> URL? {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = logDirectory.appendingPathComponent("clean-\(stamp.string(from: Date())).log")
        do {
            try PrivateStorage.write(lines.joined(separator: "\n") + "\n", to: url)
            return url
        } catch {
            return nil
        }
    }
}
