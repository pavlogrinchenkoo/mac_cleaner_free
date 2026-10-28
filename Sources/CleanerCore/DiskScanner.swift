import Foundation

/// Знаходить, що можна почистити, і вимірює розміри.
public final class DiskScanner: Sendable {
    public let ruleSet: RuleSet
    public let safety: SafetyPolicy
    private let home: URL
    private let runner: CommandRunner
    private let fileSettings: FileScanSettings?
    private let applicationRoots: [URL]?
    private let maxConcurrentMeasurements: Int

    /// Службові файли, які не варто показувати як окремі елементи.
    private static let ignoredNames: Set<String> = [".DS_Store", ".localized", ".com.apple.timemachine.donotpresent"]

    public init(
        ruleSet: RuleSet,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        projectRoots: [URL] = [],
        fileSettings: FileScanSettings? = nil,
        systemRoots: [String] = SystemPathGuard.defaultRoots,
        applicationRoots: [URL]? = nil,
        runner: CommandRunner = ProcessRunner(),
        maxConcurrentMeasurements: Int = 6
    ) {
        self.ruleSet = ruleSet
        self.home = home
        self.fileSettings = fileSettings
        self.applicationRoots = applicationRoots
        self.safety = SafetyPolicy(
            home: home, projectRoots: projectRoots, fileRoots: fileSettings?.roots ?? [],
            systemRoots: systemRoots, applicationRoots: applicationRoots)
        self.runner = runner
        self.maxConcurrentMeasurements = maxConcurrentMeasurements
    }

    // MARK: - Пошук елементів

    /// Швидкий етап: лише перелічує папки за шляхами з правил, без вимірювання розмірів.
    /// Правила з `provider` повертаються порожніми: їх заповнює `discoverDynamic()`.
    public func discover() -> [RuleResult] {
        let regular = ruleSet.rules.filter { !$0.catchAll }
        let catchAll = ruleSet.rules.filter(\.catchAll)

        var results = regular.map { discover(rule: $0) }

        // Те, що вже покрито точнішими правилами, «решті» не віддаємо.
        let claimed = results.flatMap { $0.entries.map(\.id) }
        results += catchAll.map { rule in
            var result = discover(rule: rule)
            result.entries.removeAll { entry in
                claimed.contains { other in
                    other == entry.id || other.hasPrefix(entry.id + "/") || entry.id.hasPrefix(other + "/")
                }
            }
            return result
        }

        // Повертаємо у порядку файлу правил.
        let order = Dictionary(uniqueKeysWithValues: ruleSet.rules.enumerated().map { ($1.id, $0) })
        return results.sorted { (order[$0.rule.id] ?? 0) < (order[$1.rule.id] ?? 0) }
    }

    /// Повільніший етап: симулятори (запуск `simctl`), проєкти, резервні копії, програми.
    public func discoverDynamic() -> [RuleResult] {
        var results: [RuleResult] = []
        for rule in ruleSet.rules {
            guard let provider = rule.provider else { continue }
            let entries: [Entry]
            switch provider {
            case "simctl.devices": entries = SimulatorProvider.deviceEntries(runner: runner, ruleID: rule.id, home: home)
            case "simctl.runtimes": entries = SimulatorProvider.runtimeEntries(runner: runner, ruleID: rule.id)
            default: entries = []
            }
            results.append(RuleResult(rule: rule, entries: entries))
        }
        results += ProjectScanner.discover(guard: safety.artifacts)
        results.append(BackupProvider.discover(home: home))
        results.append(AppProvider.discover(home: home, roots: applicationRoots))
        let appRoots = applicationRoots ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        results.append(AdobeVersions.discover(roots: appRoots))
        results.append(AdobeSettings.discover(home: home, applicationRoots: appRoots))
        return results
    }

    private func discover(rule: CleanupRule) -> RuleResult {
        // Правила з provider наповнює discoverDynamic().
        guard rule.provider == nil else { return RuleResult(rule: rule, entries: []) }

        var matches: [(url: URL, prefix: String)] = []
        var accessError: String?

        for pattern in rule.paths {
            let prefix = wildcardFreePrefix(of: pattern)
            for match in PathExpander.expand(pattern, home: home) {
                switch rule.granularity {
                case .selfItem:
                    matches.append((match, prefix))
                case .children:
                    do {
                        // Будуємо шлях від `match`, а не беремо URL від системи: вона розкриває symlink-и
                        // (/var → /private/var), і той самий каталог отримав би різні id в різних правилах.
                        let names = try FileManager.default.contentsOfDirectory(atPath: match.path)
                        matches.append(contentsOf: names.map { (match.appendingPathComponent($0), prefix) })
                    } catch where FullDiskAccess.isDenied(error) {
                        accessError = "Немає доступу до \(match.lastPathComponent). Потрібен Full Disk Access."
                    } catch {
                        // Не папка або зникла: пропускаємо.
                    }
                }
            }
        }

        let scope: EntryScope = rule.requiresAdmin ? .system : .home
        let action: EntryAction = rule.moveToTrash ? .trashPaths : .removePaths

        var entries: [Entry] = []
        var seen = Set<String>()
        for (url, prefix) in matches {
            let name = url.lastPathComponent
            if Self.ignoredNames.contains(name) { continue }
            if rule.excludeNames.contains(where: { PathExpander.matches(name: name, pattern: $0) }) { continue }
            if !rule.includeNames.isEmpty,
               !rule.includeNames.contains(where: { PathExpander.matches(name: name, pattern: $0) }) { continue }
            guard (try? validate(url, scope: scope)) != nil, seen.insert(url.path).inserted else { continue }

            var entry = Entry(
                ruleID: rule.id, url: url,
                name: rule.companions.isEmpty ? nil : baseName(of: url),
                scope: scope, action: action,
                companions: companionURLs(for: url, templates: rule.companions, scope: scope))

            if rule.ownerFromPrefix, rule.granularity == .selfItem {
                // `Application Support/Figma/DesktopProfile/v43/Cache` → власник «Figma», решта в підзаголовку.
                let relative = url.path.dropFirst(prefix.count).split(separator: "/").map(String.init)
                guard let owner = relative.first else { continue }
                if rule.excludeOwners.contains(where: { PathExpander.matches(name: owner, pattern: $0) }) { continue }
                entry.ownerName = owner
                entry.name = owner
                entry.subtitle = relative.dropFirst().joined(separator: "/")
            }
            entries.append(entry)
        }

        // Усі кеші однієї програми зводимо в один елемент (Figma: Cache, Code Cache, GPUCache… у v39–v43).
        if rule.ownerFromPrefix, rule.granularity == .selfItem {
            entries = Dictionary(grouping: entries, by: { $0.ownerName ?? $0.name }).values.map { group in
                let sorted = group.sorted { $0.id < $1.id }
                var merged = sorted[0]
                merged.companions = sorted.dropFirst().map(\.url)
                let kinds = Array(Set(sorted.map { $0.url.lastPathComponent })).sorted()
                merged.subtitle = "теки: \(sorted.count) (\(kinds.prefix(3).joined(separator: ", "))\(kinds.count > 3 ? "…" : ""))"
                return merged
            }
        }

        if rule.keepNewestVersion {
            entries = entries.filter { VersionedName($0.name) != nil }
            let newest = Set(VersionFamily.newestPerFamily(names: entries.map(\.name)).values)
            for index in entries.indices where newest.contains(entries[index].name) {
                entries[index].lockedReason = "Остання версія, зараз у використанні"
            }
        }

        entries.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return RuleResult(rule: rule, entries: entries, accessError: accessError)
    }

    /// Незмінна частина шаблону до першого `*`, `?`, `[` чи `{`: `~/Library/Containers/*/Data` → `<home>/Library/Containers`.
    private func wildcardFreePrefix(of pattern: String) -> String {
        let expanded = PathExpander.expandTilde(pattern, home: home)
        var parts: [Substring] = []
        for component in expanded.split(separator: "/", omittingEmptySubsequences: true) {
            if component.contains(where: { "*?[{".contains($0) }) { break }
            parts.append(component)
        }
        return "/" + parts.joined(separator: "/")
    }

    private func validate(_ url: URL, scope: EntryScope) throws {
        switch scope {
        case .home: try safety.home.validate(url)
        case .system: try safety.system.validate(url)
        case .project: try safety.artifacts.validate(url)
        case .userFile: try safety.files.validate(url)
        case .backup: try safety.backups.validate(url)
        case .application: break
        }
    }

    /// `Pixel.avd` → `Pixel`.
    private func baseName(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Супутні файли (`{base}.ini`), що реально існують і проходять ті самі перевірки безпеки.
    private func companionURLs(for url: URL, templates: [String], scope: EntryScope) -> [URL] {
        let base = baseName(of: url)
        let directory = url.deletingLastPathComponent()
        return templates.compactMap { template in
            let candidate = directory.appendingPathComponent(template.replacingOccurrences(of: "{base}", with: base))
            var st = stat()
            guard lstat(candidate.path, &st) == 0, (try? validate(candidate, scope: scope)) != nil else { return nil }
            return candidate
        }
    }

    // MARK: - Вимірювання

    /// Повний цикл: знайти елементи, паралельно виміряти розміри, потім шукати файли й дублікати.
    public func scan() -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [self] in
                let base = discover()
                continuation.yield(.discovered(base))

                continuation.yield(.status("Шукаю проєкти, симулятори й програми…"))
                let dynamic = discoverDynamic()
                if !dynamic.isEmpty { continuation.yield(.appended(dynamic)) }

                // Заблоковані «останні версії» не міряємо: їх все одно не можна видаляти.
                var toMeasure = base.flatMap(\.entries)
                let replaced = Set(dynamic.map(\.id))
                toMeasure.removeAll { replaced.contains($0.ruleID) }
                toMeasure += dynamic.flatMap(\.entries)
                toMeasure = toMeasure.filter { $0.lockedReason == nil || $0.presetUsage != nil || $0.informational }

                continuation.yield(.status("Рахую розміри…"))
                let home = self.home
                await withTaskGroup(of: (String, DiskUsage).self) { group in
                    var iterator = toMeasure.makeIterator()
                    func addNext() {
                        guard let entry = iterator.next() else { return }
                        group.addTask { (entry.id, Self.usage(of: entry, home: home)) }
                    }
                    for _ in 0..<maxConcurrentMeasurements { addNext() }
                    while let (id, usage) = await group.next() {
                        continuation.yield(.measured(id: id, usage))
                        if Task.isCancelled { group.cancelAll() } else { addNext() }
                    }
                }

                // Найповільніше наприкінці, щоб решта результатів з'явилась одразу.
                if let settings = fileSettings, !Task.isCancelled {
                    let files = FileScanner.results(
                        settings: settings, home: home,
                        status: { continuation.yield(.status($0)) }, isCancelled: { Task.isCancelled })
                    if !files.isEmpty && !Task.isCancelled {
                        continuation.yield(.appended(files))
                        for entry in files.flatMap(\.entries) {
                            if let usage = entry.presetUsage { continuation.yield(.measured(id: entry.id, usage)) }
                        }
                    }
                }

                continuation.yield(.status(nil))
                continuation.yield(.finished)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Розмір елемента. Для артефактів проєктів «остання зміна» враховує і роботу над самим проєктом.
    static func usage(of entry: Entry, home: URL) -> DiskUsage {
        if let preset = entry.presetUsage { return preset }
        var usage = DiskSize.measure(entry.url)
        for companion in entry.companions { usage.bytes += DiskSize.measure(companion).bytes }
        if entry.scope == .project,
           let activity = ProjectActivity.newest(in: entry.url.deletingLastPathComponent(), home: home) {
            usage.lastModified = max(usage.lastModified ?? .distantPast, activity)
        }
        // Для програм і резервних копій дата береться з метаданих, а не з файлів усередині.
        if let activity = entry.activityDate { usage.lastModified = activity }
        return usage
    }

    // MARK: - Блокування

    /// Причини блокування на рівні правил (запущені застосунки/процеси). `pgrep` викликається раз на правило.
    public static func ruleBlocks(for rules: [CleanupRule], snapshot: RunningSnapshot) -> [String: String] {
        var blocks: [String: String] = [:]
        for rule in rules {
            if let reason = RunningProbe.blockReason(for: rule, snapshot: snapshot) {
                blocks[rule.id] = reason
            }
        }
        return blocks
    }

    /// Чому саме цей елемент зараз не можна видаляти (або `nil`).
    public static func blockReason(
        for entry: Entry, rule: CleanupRule, ruleBlock: String?, snapshot: RunningSnapshot, now: Date = Date()
    ) -> String? {
        if let locked = entry.lockedReason { return locked }
        if let ruleBlock { return ruleBlock }
        if let days = rule.protectRecentDays, let last = entry.measurement?.lastModified {
            let age = Int(now.timeIntervalSince(last) / 86_400)
            if age < days { return age == 0 ? "Використовувався сьогодні" : "Використовувався \(age) дн. тому" }
        }
        if rule.skipRunningAppCaches, snapshot.ownsCache(named: entry.ownerName ?? entry.name) {
            return "Застосунок запущений"
        }
        return nil
    }

    /// Рішення «вибирати за замовчуванням чи ні» разом із причиною: щоб у діагностиці було видно логіку.
    public struct DefaultDecision: Sendable, Equatable {
        public let selected: Bool
        public let reason: String
    }

    public static func defaultDecision(_ entry: Entry, rule: CleanupRule, now: Date = Date()) -> DefaultDecision {
        // Те, що вимагає пароля, ніколи не вибираємо саме: пароль питаємо лише коли користувач сам попросив.
        if rule.requiresAdmin { return DefaultDecision(selected: false, reason: "потрібен пароль адміна: лише вручну") }
        // Особисті файли, бекапи й програми користувач вибирає лише вручну.
        switch entry.scope {
        case .userFile: return DefaultDecision(selected: false, reason: "особисті файли: лише вручну")
        case .backup: return DefaultDecision(selected: false, reason: "резервна копія: лише вручну")
        case .application: return DefaultDecision(selected: false, reason: "програма: лише вручну")
        default: break
        }
        if let days = rule.autoSelectOlderThanDays {
            guard let last = entry.measurement?.lastModified else {
                return DefaultDecision(selected: false, reason: "невідомо, коли змінювалось")
            }
            let age = Int(now.timeIntervalSince(last) / 86_400)
            return age >= days
                ? DefaultDecision(selected: true, reason: "не змінювалось \(age) дн. (потрібно від \(days))")
                : DefaultDecision(selected: false, reason: "активність \(age) дн. тому (потрібно від \(days))")
        }
        return rule.risk == .safe
            ? DefaultDecision(selected: true, reason: "безпечний кеш")
            : DefaultDecision(selected: false, reason: "обережне правило: лише вручну")
    }

    /// Чи вибирати елемент за замовчуванням після скану.
    public static func isSelectedByDefault(_ entry: Entry, rule: CleanupRule, now: Date = Date()) -> Bool {
        defaultDecision(entry, rule: rule, now: now).selected
    }
}
