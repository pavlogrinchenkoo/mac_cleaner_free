import AppKit
import CleanerCore

/// Headless self-check: `Cleaner --selftest`.
/// Runs the real app model on real data, does a DRY RUN (nothing is deleted), checks its own behaviour and
/// writes a report. For a quick check without clicking: `scripts/selftest.sh`. Output is English
/// (set `CLEANER_LANGUAGE=uk` to check the Ukrainian report).
@MainActor
enum SelfTest {
    static var isRequested: Bool { CommandLine.arguments.contains("--selftest") }

    static func runIfRequested(model: AppModel) {
        guard isRequested else { return }
        // Watchdog: if something hangs, don't leave the process running forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1500) {
            print("❌ TIMEOUT: the self-check did not finish in 25 minutes")
            fflush(stdout)
            exit(2)
        }
        Task { @MainActor in
            let code = await run(model: model)
            fflush(stdout)
            exit(code)
        }
    }

    private static let personalScopes: Set<EntryScope> = [.userFile, .backup, .application]

    private static func wait(_ timeout: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return condition()
    }

    /// The start of the summary line "Added MANUALLY by the user: N item(s), <size>.", in the current language.
    private static func manualAddedPrefix(_ count: Int) -> String {
        L("Added MANUALLY by the user: %ld item(s), %@.", count, "\u{1}").components(separatedBy: "\u{1}")[0]
    }

    private static func format(_ bytes: Int64) -> String {
        Loc.bytes(bytes)
    }

    static func run(model: AppModel) async -> Int32 {
        // The checks read the report through `DiagnosticMarkers`, so they work in either language; English by
        // default so that scripts/selftest.sh can grep the report.
        Loc.current = Loc.initialLanguage(preferred: [])
        var lines: [String] = []
        var failed = 0
        func check(_ ok: Bool, _ title: String, _ detail: String = "") {
            lines.append("\(ok ? "✅" : "❌") \(title)\(detail.isEmpty ? "" : ": \(detail)")")
            if !ok { failed += 1 }
        }
        func info(_ text: String) { lines.append("ℹ️  \(text)") }
        func emit() {
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            let text = lines.joined(separator: "\n") + "\n"
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cleaner/logs")
            try? PrivateStorage.write(text, to: dir.appendingPathComponent("selftest-\(stamp.string(from: Date())).txt"))
            print(text)
        }

        info("Cleaner \(SystemDescription.appVersion), macOS \(SystemDescription.macOSVersion), Full Disk Access: \(FullDiskAccess.isGranted() ? "granted" : "not granted")")
        info("MODE: dry run only, nothing is deleted")

        // 1. Scan
        let scanStart = Date()
        model.start()
        let scanned = await wait(900) { model.phase == .idle && model.lastScan != nil }
        check(scanned, "Scan finished", "\(Int(Date().timeIntervalSince(scanStart))) s")
        guard scanned else { emit(); return 1 }

        let all = model.allEntries
        let auto = model.selectedEntries
        let autoBytes = auto.reduce(Int64(0)) { $0 + $1.bytes }
        info("Found \(all.count) items in \(model.results.filter { !$0.entries.isEmpty }.count) rules; auto-selected \(auto.count) (\(format(autoBytes)))")

        // 2. The automatic selection must be safe
        let personalAuto = auto.filter { personalScopes.contains($0.scope) }
        check(personalAuto.isEmpty, "Personal files, backups and apps are not auto-selected",
              personalAuto.prefix(3).map(\.name).joined(separator: ", "))
        let adminAuto = auto.filter { $0.scope == .system || (model.rule($0.ruleID)?.requiresAdmin ?? false) }
        check(adminAuto.isEmpty, "Nothing that needs a password is auto-selected")
        check(auto.allSatisfy { model.blockReason($0) == nil }, "Nothing blocked is selected (running apps etc.)")
        let carefulAuto = auto.filter { entry in
            guard let rule = model.rule(entry.ruleID) else { return false }
            return rule.risk == .careful && rule.autoSelectOlderThanDays == nil
        }
        check(carefulAuto.isEmpty, "\"Careful\" rules are not auto-selected", carefulAuto.prefix(3).map(\.name).joined(separator: ", "))
        check(model.manuallyChanged.isEmpty, "Nothing is marked \"manual\" before any user action")
        let blockedCount = all.filter { model.blockReason($0) != nil }.count
        info("Blocked right now: \(blockedCount) items (running apps, newest version etc.)")

        // 3. Dry run #1: the same as the user would press (with the disk usage map)
        var previousLog = model.report?.logURL
        let dryStart = Date()
        model.dryRun = true
        model.diagnosticsSurveyEnabled = true
        model.clean()
        let firstDone = await wait(1200) { model.phase == .idle && model.report != nil && model.report?.logURL != previousLog }
        check(firstDone, "Dry run #1 finished", "\(Int(Date().timeIntervalSince(dryStart))) s")
        guard firstDone, let first = model.report else { emit(); return 1 }
        let firstLog = first.logURL
        check(first.dryRun && first.failures.isEmpty, "The dry run has no errors", "errors: \(first.failures.count), skipped: \(first.skipped.count)")
        check(firstLog != nil && FileManager.default.fileExists(atPath: firstLog?.path ?? ""), "The diagnostic file was created")
        if let firstLog, let text = try? String(contentsOf: firstLog, encoding: .utf8) {
            lines.append("LOG: \(firstLog.path)")
            check(text.contains(DiagnosticMarkers.summaryHeader) && text.contains(DiagnosticMarkers.surveyHeader), "The file has a summary and a disk usage map", "\(text.utf8.count / 1024) KB")
            check(text.contains(manualAddedPrefix(0)), "The file has no manual changes (there were none)")
            // The legend in the header contains the same words, so look for the marker at the start of an item line.
            func entryLines(_ marker: String) -> Int { text.components(separatedBy: "\n").filter { $0.hasPrefix("  \(marker) ") && $0.dropFirst(marker.count + 3).first?.isNumber == true }.count }
            check(entryLines(DiagnosticMarkers.manualOn) == 0 && entryLines(DiagnosticMarkers.manualOff) == 0, "No item line is marked \"manual\"")
            check(entryLines(DiagnosticMarkers.unexplained) == 0 && !text.contains(DiagnosticMarkers.unexplainedPhrase), "Nothing is selected for an unknown reason")
            check(text.contains(DiagnosticMarkers.installedAppsTitle), "The file has the list of installed apps")
            check(!text.contains(" Zero KB"), "The file has no \"Zero KB\"")
        }

        // 4. Simulated user actions: click a group, a "no bulk select" rule, an item
        let personalBefore = model.selectedEntries.filter { personalScopes.contains($0.scope) }.count
        for group in model.groups { model.toggleGroup(group.id) }
        let personalAfterGroups = model.selectedEntries.filter { personalScopes.contains($0.scope) }.count
        check(personalAfterGroups == personalBefore, "A group checkbox does not select personal items", "before: \(personalBefore), after: \(personalAfterGroups)")
        for group in model.groups { model.toggleGroup(group.id) }   // restore

        let nonBulk = model.results.first { !$0.rule.bulkSelectable && $0.entries.contains(where: model.isSelectable) }
        if let nonBulk {
            let snapshot = model.selected
            model.toggle(nonBulk)
            check(model.selected == snapshot, "\"Select all\" is disabled for \"\(nonBulk.rule.title)\"")
        } else {
            info("No rule without bulk select has selectable items: check skipped")
        }

        let candidate = all.first { personalScopes.contains($0.scope) && model.isSelectable($0) }
        var manualPath: String?
        if let candidate {
            model.toggle(candidate)
            check(model.selected.contains(candidate.id) && model.manuallyChanged.contains(candidate.id),
                  "Manually selecting a personal item works and is marked \"manual\"", candidate.name)
            manualPath = candidate.url.path
        } else {
            info("No selectable personal items on this Mac: manual selection not checked")
        }

        // 5. Dry run #2 (no disk usage map, fast): the file must show the manual selection
        previousLog = model.report?.logURL
        model.diagnosticsSurveyEnabled = false
        model.clean()
        let secondDone = await wait(600) { model.phase == .idle && model.report?.logURL != previousLog }
        check(secondDone, "Dry run #2 finished")
        if secondDone, let log = model.report?.logURL, let text = try? String(contentsOf: log, encoding: .utf8) {
            if manualPath != nil {
                func entryLines(_ marker: String) -> Int { text.components(separatedBy: "\n").filter { $0.hasPrefix("  \(marker) ") && $0.dropFirst(marker.count + 3).first?.isNumber == true }.count }
                check(entryLines(DiagnosticMarkers.manualOn) == 1, "The file marks exactly one manual selection (`\(DiagnosticMarkers.manualOn)`)", "lines: \(entryLines(DiagnosticMarkers.manualOn))")
                check(text.contains(manualAddedPrefix(1)), "The summary counts manual changes (a group click there and back does not count)")
                check(entryLines(DiagnosticMarkers.unexplained) == 0, "A manual selection does not look like an error")
            }
            check(text.contains(DiagnosticMarkers.auto), "The file marks automatic selection (`\(DiagnosticMarkers.auto)`)")
        }

        // 6. Nothing was deleted
        var missing: [String] = []
        for entry in all where entry.action == .removePaths || entry.action == .trashPaths {
            var st = stat()
            if lstat(entry.url.path, &st) != 0 { missing.append(entry.url.path) }
        }
        check(missing.isEmpty, "Everything is still in place after the dry runs", missing.prefix(3).joined(separator: ", "))

        lines.append("")
        lines.append(failed == 0 ? "RESULT: all checks passed" : "RESULT: failed checks — \(failed)")
        emit()
        return failed == 0 ? 0 : 1
    }
}
