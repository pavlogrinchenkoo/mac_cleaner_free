import Darwin
import Foundation

public struct CleanItemResult: Sendable, Identifiable {
    public enum Outcome: Sendable {
        /// Видалено повністю.
        case removed
        /// Переміщено в Кошик: місце звільниться, коли Кошик очистять.
        case trashed
        /// Пробний запуск: нічого не змінено.
        case dryRun
        /// Пропущено з причиною (зник, заблоковано, не пройшов перевірку, скасовано).
        case skipped(String)
        /// Помилка; `bytes` — скільки встигло звільнитись до неї.
        case failed(String)
    }

    /// Що було б/було зроблено: видалення назовсім чи Кошик.
    public enum Disposal: Sendable { case delete, trash }

    public let id: String
    public let path: String
    public let outcome: Outcome
    public let disposal: Disposal
    /// Скільки місця торкнулось (для `dryRun` — скільки було б).
    public let bytes: Int64
    /// Попередження, що не змінює результату (наприклад, залишок не вдалося перемістити).
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

    /// Місце, яке звільнено (або було б) видаленням назовсім.
    public var freedBytes: Int64 {
        items.filter { $0.disposal == .delete }.reduce(0) { $0 + $1.bytes }
    }
    /// Те, що переміщено (або було б) в Кошик: місце звільниться після його очищення.
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

/// Видаляє вибрані елементи. Перед кожною дією заново перевіряє безпеку.
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

    /// Синхронна, довга: викликай з фонового потоку/Task.
    public func clean(
        entries: [Entry],
        rules: [CleanupRule],
        dryRun: Bool,
        progress: @Sendable (_ done: Int, _ total: Int, _ current: String) -> Void = { _, _, _ in }
    ) -> CleanReport {
        let rulesByID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        // Знімок стану береться заново саме зараз, а не під час сканування.
        let snapshot = RunningSnapshot.current()
        let ruleBlocks = DiskScanner.ruleBlocks(for: rules, snapshot: snapshot)

        let homePath = safety.home.home.path
        var logLines: [String] = []
        var items: [CleanItemResult] = []
        let formatter = ISO8601DateFormatter()
        logLines.append("# Cleaner \(dryRun ? "DRY-RUN" : "CLEAN") \(formatter.string(from: Date()))")

        // Оригінали дублікатів, які видаляються в цій же пачці: їх не чіпаємо, інакше разом із копією зникне й остання версія.
        let keeperPaths = Set(entries.compactMap { $0.keeper?.path })

        // Дії, що потребують пароля адміна, збираємо в одну пачку: один запит пароля на все.
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
                // Залишки (в ~/Library) належать користувачеві: їх переносимо в Кошик, лише якщо програма зникла.
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

    /// Результат для елемента, видаленого пачкою з паролем: дивимось, чи він справді зник.
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
            // Команда відпрацювала, але елемент лишився: типово SIP або файл зайнятий.
            let remaining = DiskSize.measure(entry.url).bytes
            return result(.failed(L("The system did not allow deletion")), max(0, entry.bytes - remaining))
        }
    }

    /// Копію можна прибрати лише поки оригінал на місці й не змінився.
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

    /// Виконує дію для елемента, що не потребує адміна.
    private func perform(_ entry: Entry, before: Int64, finish: (CleanItemResult.Outcome, Int64, String?) -> Void) {
        switch entry.action {
        case .removePaths:
            do {
                for url in [entry.url] + entry.companions { try Self.remove(url) }
                finish(.removed, before, nil)
            } catch {
                // Могло видалитись частково: рахуємо, скільки реально звільнилось.
                let remaining = DiskSize.measure(entry.url).bytes
                finish(.failed(error.localizedDescription), max(0, before - remaining), nil)
            }
        case .trashPaths:
            do {
                // Спершу основне, потім залишки: якщо основне не вдалось, залишки лишаються на місці.
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

    /// Якщо `url` — symlink, `removeItem` прибирає сам symlink, а не те, на що він вказує.
    private static func remove(_ url: URL) throws {
        let fm = FileManager.default
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return }
        do {
            try fm.removeItem(at: url)
        } catch {
            // Типова причина: у дереві є папки без права запису (Gradle, Xcode). Додаємо право й пробуємо ще раз.
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
