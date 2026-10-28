import AppKit
import CleanerCore
import Observation

enum TriState {
    case off, mixed, on
}

/// Потокобезпечний прапорець «зупинити», який читає фонова діагностика.
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

    /// Єдиний екземпляр: його використовує і вікно, і безголовий режим самоперевірки.
    static let shared = AppModel()

    /// Вибір мови інтерфейсу. `system` = мова Mac (або CLEANER_LANGUAGE); `en`/`uk` примусово.
    enum LanguageChoice: String, CaseIterable, Identifiable {
        case system, en, uk

        var id: String { rawValue }

        /// Назви мов показуємо їхніми ж мовами й не перекладаємо; «Системна» перекладається.
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
    /// Ці групи видно завжди: у них є налаштування.
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
    /// Що користувач вибрав чи зняв руками (відрізняємо від автоматичного вибору в діагностиці).
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
    /// Що робить скан просто зараз («Шукаю дублікати…»).
    private(set) var statusText: String?
    /// Іде збір карти зайнятого місця (її можна пропустити).
    private(set) var collectingDiagnostics = false
    private var diagnosticsStop = StopFlag()
    private(set) var largeFileMinMB = 100
    /// Що вибрав користувач (за замовчуванням системна мова) і мова, яка з цього випливає.
    private(set) var languageChoice: LanguageChoice = .system
    private(set) var language: Language = .en

    /// Чи збирати карту зайнятого місця під час пробного запуску (довго; самоперевірка може її пропустити).
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
    /// Доступ з'явився посеред скану: після нього скануємо ще раз.
    private var rescanAfterScan = false
    private var entryLocation: [String: (rule: Int, entry: Int)] = [:]

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    // MARK: - Життєвий цикл

    /// Правила вантажимо одразу, до першого кадру: тоді сайдбар не перебудовується й вибір групи не змінюється
    /// посеред відмальовування (це викликало попередження NSTableView про реентерабельність).
    init() {
        // Мову застосовуємо першою: правила й тексти скану мають одразу вийти потрібною мовою.
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
        // Перший запуск без дозволу: пояснюємо, як його дати (один раз; далі лишається банер).
        if !hasFullDiskAccess, !UserDefaults.standard.bool(forKey: Self.fdaDismissedKey) {
            showFullDiskAccessGuide = true
        }
        scan()
    }

    /// Оновлює диск і стан Full Disk Access. Якщо доступ щойно з'явився, дані скану застарілі (Кошик, бекапи,
    /// Mail були недоступні), тож скануємо заново автоматично.
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

    /// Після видачі Full Disk Access macOS застосовує дозвіл лише до нового запуску.
    var canRelaunch: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    func relaunch() {
        guard canRelaunch else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Шлях передаємо окремим аргументом ($0), а не вставляємо в команду.
        process.arguments = ["-c", "/bin/sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: - Мова

    /// Перемикає мову: зберігає вибір, перечитує правила (назви груп і правил) і скануємо заново, бо частину
    /// текстів (причини блокування, підписи елементів) створює саме скан. Вибір у списку скидається.
    func setLanguageChoice(_ choice: LanguageChoice) {
        guard phase != .cleaning, choice != languageChoice else { return }
        languageChoice = choice
        UserDefaults.standard.set(choice.rawValue, forKey: Self.languageKey)
        let resolved = choice.resolved
        // «Системна» могла дати ту саму мову, що й була: перемальовувати нічого.
        guard resolved != language else { return }
        language = resolved
        Loc.current = resolved
        reloadRules()
        // До `start()` сканера ще немає: його створить `start()` з уже перечитаними правилами.
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

    // MARK: - Папки проєктів

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

    /// Де шукати особисті файли: типові папки користувача, без папок проєктів (для них є своя вкладка).
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

    // MARK: - Сканування

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
                // Подія від скасованого скану не має зачепити свіжий стан.
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
                    // Об'єднуємо оновлення, щоб інтерфейс не перемальовувався на кожну подію.
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

    /// Викликається періодично: користувач міг запустити чи закрити застосунок.
    func refreshRunning() async {
        guard phase != .cleaning else { return }
        let fresh = RunningSnapshot.current()
        let blocks = await Self.computeRuleBlocks(results.map(\.rule), snapshot: fresh)
        snapshot = fresh
        ruleBlocks = blocks
        // Те, що стало заблоковане, більше не вважаємо вибраним.
        for entry in allEntries where selected.contains(entry.id) && !isSelectable(entry) {
            selected.remove(entry.id)
        }
        refreshSystemState()
    }

    // MARK: - Доступ до даних

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

    /// Групи з налаштуваннями («Проєкти», «Файли») видно завжди, решту лише коли є що показати.
    func isGroupVisible(_ group: CleanupGroup) -> Bool {
        Self.alwaysVisibleGroups.contains(group.id) || !visibleResults(in: group.id).isEmpty
    }

    /// Якщо вибрана група зникла чи порожня, переходимо до першої з даними.
    private func ensureValidSelection() {
        let visible = groups.filter(isGroupVisible)
        if let current = selectedGroupID, visible.contains(where: { $0.id == current }),
           !visibleResults(in: current).isEmpty || Self.alwaysVisibleGroups.contains(current) { return }
        selectedGroupID = visible.first(where: { !visibleResults(in: $0.id).isEmpty })?.id ?? visible.first?.id
    }

    /// Правила, які варто показувати у групі.
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

    // MARK: - Розміри й вибір

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
    /// Скільки вибраного потребує пароля адміна.
    var selectedAdminCount: Int { selectedEntries.filter { $0.scope == .system || $0.needsAdmin }.count }
    /// Особисті файли, бекапи й програми серед вибраного: їх варто перевірити ще раз.
    var selectedPersonalCount: Int {
        selectedEntries.filter { [.userFile, .backup, .application].contains($0.scope) }.count
    }
    /// Те, що піде в Кошик (можна повернути), і те, що видаляється назовсім.
    var selectedTrashBytes: Int64 { selectedEntries.filter { $0.action == .trashPaths }.reduce(0) { $0 + $1.bytes } }
    var selectedTrashCount: Int { selectedEntries.filter { $0.action == .trashPaths }.count }
    var selectedDeleteBytes: Int64 { selectedBytes - selectedTrashBytes }

    func state(of result: RuleResult) -> TriState {
        triState(for: result.entries.filter(isSelectable))
    }

    /// Рекомендоване: те саме, що вибирається за замовчуванням після скану. Групові чекбокси працюють лише з ним,
    /// тому одним кліком не можна вибрати особисті файли, програми, бекапи чи кеші, які краще перевірити.
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

    /// Чи можна вибрати все в правилі одним чекбоксом.
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

    // MARK: - Очищення

    func clean() {
        guard let scanner, phase == .idle else { return }
        let entries = selectedEntries
        let dryRun = dryRun
        // У пробному запуску діагностику збирають і без вибору: вона потрібна, щоб налаштувати правила.
        guard !entries.isEmpty || dryRun else { return }

        diskBeforeClean = DiskInfo.current()
        phase = .cleaning
        cleanProgress = CleanProgress(done: 0, total: max(entries.count, 1), current: "")

        let engine = CleanEngine(safety: scanner.safety)
        // Правила беремо з результатів скану: там і вбудовані, і динамічні (проєкти, файли).
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

            // Пробний запуск завжди лишає діагностичний файл, який можна переслати розробнику.
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
            // Після справжнього видалення оновлюємо список, щоб він відповідав диску.
            if !dryRun { self.scan() }
        }
    }

    /// Зупиняє збір карти місця; звіт збережеться з тим, що встигли дорахувати.
    func skipDiagnostics() {
        diagnosticsStop.set()
    }

    /// Знімок стану для діагностичного файлу (без довгих операцій: їх робить фонове завдання).
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

    // MARK: - Допоміжне

    func revealInFinder(_ entry: Entry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }
}
