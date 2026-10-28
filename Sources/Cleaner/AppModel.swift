import AppKit
import CleanerCore
import Observation

enum TriState {
    case off, mixed, on
}

/// Thread-safe "stop" flag read by the background diagnostics.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

struct CleanProgress: Equatable {
    var done: Int
    var total: Int
    var current: String
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle, scanning, cleaning
    }

    /// The single instance: used by both the window and the headless self-test mode.
    static let shared = AppModel()

    /// Interface language choice. `system` = the Mac's language (or CLEANER_LANGUAGE); `en`/`uk` force a language.
    enum LanguageChoice: String, CaseIterable, Identifiable {
        case system, en, uk

        var id: String { rawValue }

        /// Language names are shown in their own languages and are not translated; "System default" is translated.
        var title: String {
            switch self {
            case .system: L("System default")
            case .en: Language.en.nativeName
            case .uk: Language.uk.nativeName
            }
        }

        var resolved: Language {
            switch self {
            case .system: Loc.initialLanguage()
            case .en: .en
            case .uk: .uk
            }
        }
    }

    static let projectsGroupID = "projects"
    static let filesGroupID = "files"
    /// These groups are always visible: they have settings.
    static let alwaysVisibleGroups: Set<String> = [projectsGroupID, filesGroupID]
    static let minSizeOptionsMB = [50, 100, 250, 500, 1000]
    private static let rootsKey = "projectRoots"
    private static let minSizeKey = "largeFileMinMB"
    private static let fdaDismissedKey = "fdaOnboardingDismissed"
    private static let languageKey = "interfaceLanguage"

    private(set) var phase: Phase = .idle
    private(set) var groups: [CleanupGroup] = []
    private(set) var results: [RuleResult] = []
    private(set) var selected: Set<String> = []
    /// What the user selected or deselected by hand (as opposed to the automatic selection in diagnostics).
    private(set) var manuallyChanged: Set<String> = []
    private(set) var ruleBlocks: [String: String] = [:]
    private(set) var snapshot = RunningSnapshot()
    private(set) var disk: DiskInfo?
    private(set) var diskBeforeClean: DiskInfo?
    private(set) var hasFullDiskAccess = true
    private(set) var loadError: String?
    private(set) var report: CleanReport?
    private(set) var cleanProgress: CleanProgress?
    private(set) var lastScan: Date?
    private(set) var projectRoots: [URL] = []
    private(set) var rootsMessage: String?
    /// What the scan is doing right now ("Looking for duplicates…").
    private(set) var statusText: String?
    /// The disk usage map is being collected (it can be skipped).
    private(set) var collectingDiagnostics = false
    private var diagnosticsStop = StopFlag()
    private(set) var largeFileMinMB = 100
    /// What the user chose (the system language by default) and the language that follows from it.
    private(set) var languageChoice: LanguageChoice = .system
    private(set) var language: Language = .en

    /// Whether to collect the disk usage map during a dry run (slow; the self-test may skip it).
    var diagnosticsSurveyEnabled = true
    var selectedGroupID: String?
    var dryRun = false
    var showConfirm = false
    var showReport = false
    var showFullDiskAccessGuide = false

    private var scanner: DiskScanner?
    private var ruleSet: RuleSet?
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0
    /// Access appeared in the middle of a scan: scan again once it finishes.
    private var rescanAfterScan = false
    private var entryLocation: [String: (rule: Int, entry: Int)] = [:]

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    // MARK: - Lifecycle

    /// Load the rules right away, before the first frame: then the sidebar isn't rebuilt and the group selection
    /// doesn't change in the middle of drawing (that triggered the NSTableView reentrancy warning).
    init() {
        // Apply the language first: the rules and scan texts must come out in the right language from the start.
        let savedChoice = UserDefaults.standard.string(forKey: Self.languageKey).flatMap(LanguageChoice.init(rawValue:)) ?? .system
        languageChoice = savedChoice
        language = savedChoice.resolved
        Loc.current = language
        let saved = UserDefaults.standard.integer(forKey: Self.minSizeKey)
        if Self.minSizeOptionsMB.contains(saved) { largeFileMinMB = saved }
        do {
            let set = try RuleLoader.load()
            ruleSet = set
            groups = set.groups
            selectedGroupID = set.groups.first?.id
        } catch {
            loadError = L("Could not read the rules: %@", error.localizedDescription)
        }
    }

    func start() {
        guard ruleSet != nil, scanner == nil else { return }
        loadProjectRoots()
        refreshSystemState()
        // First launch without the permission: explain how to grant it (once; after that the banner remains).
        if !hasFullDiskAccess, !UserDefaults.standard.bool(forKey: Self.fdaDismissedKey) {
            showFullDiskAccessGuide = true
        }
        scan()
    }

    /// Refreshes the disk and the Full Disk Access state. If access has just appeared, the scan data is stale (Trash,
    /// backups and Mail were inaccessible), so we rescan automatically.
    func refreshSystemState(allowRescan: Bool = true) {
        disk = DiskInfo.current()
        let granted = FullDiskAccess.isGranted()
        let justGranted = granted && !hasFullDiskAccess
        hasFullDiskAccess = granted
        guard justGranted, allowRescan, scanner != nil else { return }
        if phase == .idle { scan() } else if phase == .scanning { rescanAfterScan = true }
    }

    // MARK: - Full Disk Access

    func dismissFullDiskAccessGuide() {
        UserDefaults.standard.set(true, forKey: Self.fdaDismissedKey)
        showFullDiskAccessGuide = false
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(FullDiskAccess.settingsURL)
    }

    func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// After Full Disk Access is granted, macOS applies the permission only to a new launch.
    var canRelaunch: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    func relaunch() {
        guard canRelaunch else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Pass the path as a separate argument ($0) instead of embedding it in the command.
        process.arguments = ["-c", "/bin/sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: - Language

    /// Switches the language: saves the choice, reloads the rules (group and rule names) and rescans, because some of
    /// the texts (block reasons, item labels) are produced by the scan itself. The selection in the list is reset.
    func setLanguageChoice(_ choice: LanguageChoice) {
        guard phase != .cleaning, choice != languageChoice else { return }
        languageChoice = choice
        UserDefaults.standard.set(choice.rawValue, forKey: Self.languageKey)
        let resolved = choice.resolved
        // "System default" may have resolved to the same language as before: nothing to redraw.
        guard resolved != language else { return }
        language = resolved
        Loc.current = resolved
        reloadRules()
        // Before `start()` there is no scanner yet: `start()` will create it with the already reloaded rules.
        guard scanner != nil else { return }
        rebuildScanner()
        scan()
    }

    private func reloadRules() {
        do {
            let set = try RuleLoader.load()
            ruleSet = set
            groups = set.groups
            loadError = nil
            if selectedGroupID == nil || !set.groups.contains(where: { $0.id == selectedGroupID }) {
                selectedGroupID = set.groups.first?.id
            }
        } catch {
            loadError = L("Could not read the rules: %@", error.localizedDescription)
        }
    }

    // MARK: - Project folders

    private func loadProjectRoots() {
        if let saved = UserDefaults.standard.array(forKey: Self.rootsKey) as? [String] {
            projectRoots = saved.map { URL(fileURLWithPath: $0) }
        } else {
            projectRoots = ProjectRoots.detectDefaults(home: home)
        }
        rebuildScanner()
    }

    private func rebuildScanner() {
        guard let ruleSet else { return }
        scanner = DiskScanner(ruleSet: ruleSet, home: home, projectRoots: projectRoots, fileSettings: fileSettings)
    }

    /// Where to look for personal files: the user's standard folders, excluding project folders (they have their own
    /// tab).
    var fileSettings: FileScanSettings {
        FileScanSettings(
            roots: FileScanSettings.defaultRoots(home: home), excludedRoots: projectRoots,
            minLargeBytes: Int64(largeFileMinMB) * 1_000_000)
    }

    func setLargeFileMinMB(_ value: Int) {
        guard Self.minSizeOptionsMB.contains(value), value != largeFileMinMB else { return }
        largeFileMinMB = value
        UserDefaults.standard.set(value, forKey: Self.minSizeKey)
        rebuildScanner()
        scan()
    }

    func addProjectRoots(_ urls: [URL]) {
        rootsMessage = nil
        var changed = false
        for url in urls.map(\.standardizedFileURL) {
            guard ArtifactGuard.isValidRoot(url, home: home) else {
                rootsMessage = L("“%@” doesn't fit: the folder must be inside your home folder, but not the home folder itself or Library.", url.lastPathComponent)
                continue
            }
            if !projectRoots.contains(url) {
                projectRoots.append(url)
                changed = true
            }
        }
        if changed { rootsChanged() }
    }

    func removeProjectRoot(_ url: URL) {
        projectRoots.removeAll { $0 == url }
        rootsMessage = nil
        rootsChanged()
    }

    private func rootsChanged() {
        UserDefaults.standard.set(projectRoots.map(\.path), forKey: Self.rootsKey)
        rebuildScanner()
        scan()
    }

    // MARK: - Scanning

    func scan() {
        guard let scanner, phase != .cleaning else { return }
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        phase = .scanning
        statusText = nil
        rescanAfterScan = false
        results = []
        selected = []
        manuallyChanged = []
        entryLocation = [:]
        refreshSystemState(allowRescan: false)
        snapshot = RunningSnapshot.current()

        scanTask = Task { [weak self] in
            var pending: [(String, DiskUsage)] = []
            var lastFlush = ContinuousClock.now

            for await event in scanner.scan() {
                // An event from a cancelled scan must not touch the fresh state.
                guard let self, self.scanGeneration == generation else { return }
                switch event {
                case .discovered(let found):
                    self.results = found
                    self.indexEntries()
                    self.ruleBlocks = await Self.computeRuleBlocks(found.map(\.rule), snapshot: self.snapshot)
                    self.ensureValidSelection()
                case .appended(let found):
                    for result in found {
                        if let index = self.results.firstIndex(where: { $0.id == result.id }) {
                            self.results[index] = result
                        } else {
                            self.results.append(result)
                        }
                    }
                    self.indexEntries()
                    self.ensureValidSelection()
                case .status(let text):
                    self.statusText = text
                case .measured(let id, let usage):
                    pending.append((id, usage))
                    // Batch the updates so the UI isn't redrawn on every event.
                    if ContinuousClock.now - lastFlush > .milliseconds(120) {
                        self.apply(pending)
                        pending.removeAll()
                        lastFlush = .now
                    }
                case .finished:
                    self.apply(pending)
                    pending.removeAll()
                    self.lastScan = Date()
                    self.statusText = nil
                    self.phase = .idle
                    self.ensureValidSelection()
                    if self.rescanAfterScan { self.scan() }
                }
            }
        }
    }

    private func indexEntries() {
        entryLocation = [:]
        for (r, result) in results.enumerated() {
            for (e, entry) in result.entries.enumerated() {
                entryLocation[entry.id] = (r, e)
            }
        }
    }

    private func apply(_ updates: [(String, DiskUsage)]) {
        guard !updates.isEmpty else { return }
        for (id, usage) in updates {
            guard let location = entryLocation[id] else { continue }
            results[location.rule].entries[location.entry].measurement = usage
            let rule = results[location.rule].rule
            let entry = results[location.rule].entries[location.entry]
            if isSelectable(entry), DiskScanner.isSelectedByDefault(entry, rule: rule) { selected.insert(id) }
        }
    }

    private nonisolated static func computeRuleBlocks(_ rules: [CleanupRule], snapshot: RunningSnapshot) async -> [String: String] {
        await Task.detached { DiskScanner.ruleBlocks(for: rules, snapshot: snapshot) }.value
    }

    /// Called periodically: the user may have launched or quit an app.
    func refreshRunning() async {
        guard phase != .cleaning else { return }
        let fresh = RunningSnapshot.current()
        let blocks = await Self.computeRuleBlocks(results.map(\.rule), snapshot: fresh)
        snapshot = fresh
        ruleBlocks = blocks
        // Whatever became blocked is no longer considered selected.
        for entry in allEntries where selected.contains(entry.id) && !isSelectable(entry) {
            selected.remove(entry.id)
        }
        refreshSystemState()
    }

    // MARK: - Data access

    var allEntries: [Entry] { results.flatMap(\.entries) }

    func rule(_ id: String) -> CleanupRule? { results.first { $0.id == id }?.rule }

    func blockReason(_ entry: Entry) -> String? {
        guard let rule = rule(entry.ruleID) else { return nil }
        return DiskScanner.blockReason(for: entry, rule: rule, ruleBlock: ruleBlocks[rule.id], snapshot: snapshot)
    }

    func isSelectable(_ entry: Entry) -> Bool {
        entry.bytes > 0 && blockReason(entry) == nil
    }

    func isMeasuring(_ result: RuleResult) -> Bool {
        result.entries.contains { $0.measurement == nil && $0.lockedReason == nil }
    }

    /// Groups with settings ("Projects", "Files") are always visible, the rest only when there is something to show.
    func isGroupVisible(_ group: CleanupGroup) -> Bool {
        Self.alwaysVisibleGroups.contains(group.id) || !visibleResults(in: group.id).isEmpty
    }

    /// If the selected group has disappeared or is empty, move to the first one that has data.
    private func ensureValidSelection() {
        let visible = groups.filter(isGroupVisible)
        if let current = selectedGroupID, visible.contains(where: { $0.id == current }),
           !visibleResults(in: current).isEmpty || Self.alwaysVisibleGroups.contains(current) { return }
        selectedGroupID = visible.first(where: { !visibleResults(in: $0.id).isEmpty })?.id ?? visible.first?.id
    }

    /// The rules worth showing in the group.
    func visibleResults(in groupID: String) -> [RuleResult] {
        results.filter { $0.rule.group == groupID && isVisible($0) }
    }

    private func isVisible(_ result: RuleResult) -> Bool {
        if result.accessError != nil { return true }
        if phase == .scanning, isMeasuring(result) { return true }
        return result.entries.contains { $0.bytes > 0 }
    }

    func visibleEntries(of result: RuleResult) -> [Entry] {
        result.entries
            .filter { $0.measurement == nil || $0.bytes > 0 || $0.lockedReason != nil }
            .sorted { lhs, rhs in
                if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    // MARK: - Sizes and selection

    func totalBytes(of result: RuleResult) -> Int64 { result.entries.reduce(0) { $0 + $1.bytes } }

    func totalBytes(inGroup id: String) -> Int64 {
        visibleResults(in: id).reduce(0) { $0 + totalBytes(of: $1) }
    }

    func selectedBytes(inGroup id: String) -> Int64 {
        visibleResults(in: id).flatMap(\.entries).filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    var selectedEntries: [Entry] { allEntries.filter { selected.contains($0.id) && isSelectable($0) } }
    var selectedBytes: Int64 { selectedEntries.reduce(0) { $0 + $1.bytes } }
    var selectedCarefulCount: Int {
        selectedEntries.filter { rule($0.ruleID)?.risk == .careful }.count
    }
    /// How much of the selection needs the administrator password.
    var selectedAdminCount: Int { selectedEntries.filter { $0.scope == .system || $0.needsAdmin }.count }
    /// Personal files, backups and apps among the selection: they are worth a second look.
    var selectedPersonalCount: Int {
        selectedEntries.filter { [.userFile, .backup, .application].contains($0.scope) }.count
    }
    /// What goes to the Trash (can be restored) and what is deleted permanently.
    var selectedTrashBytes: Int64 { selectedEntries.filter { $0.action == .trashPaths }.reduce(0) { $0 + $1.bytes } }
    var selectedTrashCount: Int { selectedEntries.filter { $0.action == .trashPaths }.count }
    var selectedDeleteBytes: Int64 { selectedBytes - selectedTrashBytes }

    func state(of result: RuleResult) -> TriState {
        triState(for: result.entries.filter(isSelectable))
    }

    /// Recommended: the same as what is selected by default after a scan. Group checkboxes work only with it, so
    /// personal files, apps, backups or caches that are better reviewed can't be selected with a single click.
    func isRecommended(_ entry: Entry) -> Bool {
        guard isSelectable(entry), let rule = rule(entry.ruleID) else { return false }
        return DiskScanner.isSelectedByDefault(entry, rule: rule)
    }

    func recommendedEntries(inGroup id: String) -> [Entry] {
        visibleResults(in: id).flatMap(\.entries).filter(isRecommended)
    }

    func hasRecommended(inGroup id: String) -> Bool {
        visibleResults(in: id).contains { $0.entries.contains(where: isRecommended) }
    }

    func state(ofGroup id: String) -> TriState {
        triState(for: recommendedEntries(inGroup: id))
    }

    /// Whether everything in a rule can be selected with one checkbox.
    func canBulkSelect(_ result: RuleResult) -> Bool {
        result.rule.bulkSelectable && result.entries.contains(where: isSelectable)
    }

    private func triState(for entries: [Entry]) -> TriState {
        guard !entries.isEmpty else { return .off }
        let on = entries.filter { selected.contains($0.id) }.count
        if on == 0 { return .off }
        return on == entries.count ? .on : .mixed
    }

    func toggle(_ entry: Entry) {
        guard isSelectable(entry) else { return }
        manuallyChanged.insert(entry.id)
        if selected.contains(entry.id) { selected.remove(entry.id) } else { selected.insert(entry.id) }
    }

    func toggle(_ result: RuleResult) {
        guard result.rule.bulkSelectable else { return }
        setAll(result.entries.filter(isSelectable), on: state(of: result) != .on)
    }

    func toggleGroup(_ id: String) {
        setAll(recommendedEntries(inGroup: id), on: state(ofGroup: id) != .on)
    }

    private func setAll(_ entries: [Entry], on: Bool) {
        for entry in entries {
            manuallyChanged.insert(entry.id)
            if on { selected.insert(entry.id) } else { selected.remove(entry.id) }
        }
    }

    // MARK: - Cleaning

    func clean() {
        guard let scanner, phase == .idle else { return }
        let entries = selectedEntries
        let dryRun = dryRun
        // In a dry run diagnostics are collected even with nothing selected: they are needed to tune the rules.
        guard !entries.isEmpty || dryRun else { return }

        diskBeforeClean = DiskInfo.current()
        phase = .cleaning
        cleanProgress = CleanProgress(done: 0, total: max(entries.count, 1), current: "")

        let engine = CleanEngine(safety: scanner.safety)
        // Take the rules from the scan results: they include both built-in and dynamic ones (projects, files).
        let rules = results.map(\.rule)
        let diagnostic = dryRun ? makeDiagnosticInput() : nil
        let stop = StopFlag()
        let surveyEnabled = diagnosticsSurveyEnabled
        diagnosticsStop = stop
        let home = home
        let progressSink: @Sendable (Int, Int, String) -> Void = { [weak self] done, total, current in
            Task { @MainActor in
                self?.cleanProgress = CleanProgress(done: done, total: total, current: current)
            }
        }
        Task { [weak self] in
            var report = await Task.detached(priority: .userInitiated) {
                engine.clean(entries: entries, rules: rules, dryRun: dryRun, progress: progressSink)
            }.value

            // A dry run always leaves a diagnostics file that can be sent to the developer.
            if let diagnostic {
                let base = report
                self?.collectingDiagnostics = true
                report = await Task.detached(priority: .userInitiated) {
                    var input = diagnostic
                    input.report = base
                    input.apps = DiagnosticReport.installedApps(
                        roots: [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")])
                    input.survey = surveyEnabled ? DiskSurvey.run(
                        home: home,
                        progress: { done, total in progressSink(done, total, L("Collecting the disk usage map")) },
                        isCancelled: { stop.isSet }) : []
                    var updated = base
                    updated.logURL = DiagnosticReport.write(
                        DiagnosticReport.render(input), home: home, date: input.generatedAt, dryRun: true)
                    return updated
                }.value
            }

            guard let self else { return }
            self.collectingDiagnostics = false
            self.report = report
            self.cleanProgress = nil
            self.phase = .idle
            self.refreshSystemState()
            self.showReport = true
            // After a real deletion, refresh the list so it matches the disk.
            if !dryRun { self.scan() }
        }
    }

    /// Stops collecting the usage map; the report is saved with whatever has been computed so far.
    func skipDiagnostics() {
        diagnosticsStop.set()
    }

    /// A state snapshot for the diagnostics file (no long operations: the background task does those).
    private func makeDiagnosticInput() -> DiagnosticInput {
        let blocks = ruleBlocks
        let snap = snapshot
        return DiagnosticInput(
            appVersion: SystemDescription.appVersion, dryRun: true, macOSVersion: SystemDescription.macOSVersion,
            architecture: SystemDescription.architecture, fullDiskAccess: hasFullDiskAccess, disk: disk,
            projectRoots: projectRoots, fileSettings: fileSettings, groups: groups, results: results,
            selectedIDs: selected, manualIDs: manuallyChanged, ruleBlocks: blocks,
            blockReason: { entry, rule in
                DiskScanner.blockReason(for: entry, rule: rule, ruleBlock: blocks[rule.id], snapshot: snap)
            },
            apps: [], survey: [], home: home)
    }

    // MARK: - Helpers

    func revealInFinder(_ entry: Entry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }
}
