import Foundation

/// Finds what can be cleaned and measures sizes.
public final class DiskScanner: Sendable {
    public let ruleSet: RuleSet
    public let safety: SafetyPolicy
    private let home: URL
    private let runner: CommandRunner
    private let fileSettings: FileScanSettings?
    private let applicationRoots: [URL]?
    private let maxConcurrentMeasurements: Int

    /// Housekeeping files that should not be shown as separate entries.
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

    // MARK: - Finding entries

    /// Fast stage: only lists folders at the paths from the rules, without measuring sizes.
    /// Rules with a `provider` are returned empty: `discoverDynamic()` fills them in.
    public func discover() -> [RuleResult] {
        let regular = ruleSet.rules.filter { !$0.catchAll }
        let catchAll = ruleSet.rules.filter(\.catchAll)

        var results = regular.map { discover(rule: $0) }

        // Anything already covered by more specific rules is not handed to the "rest" rule.
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

        // Return in the order of the rules file.
        let order = Dictionary(uniqueKeysWithValues: ruleSet.rules.enumerated().map { ($1.id, $0) })
        return results.sorted { (order[$0.rule.id] ?? 0) < (order[$1.rule.id] ?? 0) }
    }

    /// Slower stage: simulators (runs `simctl`), projects, backups, apps.
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
        // Rules with a provider are filled in by discoverDynamic().
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
                        // Build the path from `match` instead of taking the URL from the system: it resolves symlinks
                        // (/var → /private/var), and the same directory would get different ids in different rules.
                        let names = try FileManager.default.contentsOfDirectory(atPath: match.path)
                        matches.append(contentsOf: names.map { (match.appendingPathComponent($0), prefix) })
                    } catch where FullDiskAccess.isDenied(error) {
                        accessError = L("No access to %@. Full Disk Access is required.", match.lastPathComponent)
                    } catch {
                        // Not a folder or it disappeared: skip.
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
                // `Application Support/Figma/DesktopProfile/v43/Cache` → owner "Figma", the rest in the subtitle.
                let relative = url.path.dropFirst(prefix.count).split(separator: "/").map(String.init)
                guard let owner = relative.first else { continue }
                if rule.excludeOwners.contains(where: { PathExpander.matches(name: owner, pattern: $0) }) { continue }
                entry.ownerName = owner
                entry.name = owner
                entry.subtitle = relative.dropFirst().joined(separator: "/")
            }
            entries.append(entry)
        }

        // All caches of one app are merged into a single entry (Figma: Cache, Code Cache, GPUCache… in v39–v43).
        if rule.ownerFromPrefix, rule.granularity == .selfItem {
            entries = Dictionary(grouping: entries, by: { $0.ownerName ?? $0.name }).values.map { group in
                let sorted = group.sorted { $0.id < $1.id }
                var merged = sorted[0]
                merged.companions = sorted.dropFirst().map(\.url)
                let kinds = Array(Set(sorted.map { $0.url.lastPathComponent })).sorted()
                let list = kinds.prefix(3).joined(separator: ", ") + (kinds.count > 3 ? "…" : "")
                merged.subtitle = L("folders: %ld (%@)", sorted.count, list)
                return merged
            }
        }

        if rule.keepNewestVersion {
            entries = entries.filter { VersionedName($0.name) != nil }
            let newest = Set(VersionFamily.newestPerFamily(names: entries.map(\.name)).values)
            for index in entries.indices where newest.contains(entries[index].name) {
                entries[index].lockedReason = L("Latest version, currently in use")
            }
        }

        entries.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return RuleResult(rule: rule, entries: entries, accessError: accessError)
    }

    /// The fixed part of a pattern before the first `*`, `?`, `[` or `{`:
    /// `~/Library/Containers/*/Data` → `<home>/Library/Containers`.
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

    /// Companion files (`{base}.ini`) that actually exist and pass the same safety checks.
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

    // MARK: - Measuring

    /// Full cycle: find entries, measure sizes in parallel, then look for files and duplicates.
    public func scan() -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [self] in
                let base = discover()
                continuation.yield(.discovered(base))

                continuation.yield(.status(L("Looking for projects, simulators and apps…")))
                let dynamic = discoverDynamic()
                if !dynamic.isEmpty { continuation.yield(.appended(dynamic)) }

                // Locked "latest versions" are not measured: they cannot be deleted anyway.
                var toMeasure = base.flatMap(\.entries)
                let replaced = Set(dynamic.map(\.id))
                toMeasure.removeAll { replaced.contains($0.ruleID) }
                toMeasure += dynamic.flatMap(\.entries)
                toMeasure = toMeasure.filter { $0.lockedReason == nil || $0.presetUsage != nil || $0.informational }

                continuation.yield(.status(L("Measuring sizes…")))
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

                // The slowest part goes last, so the rest of the results appear right away.
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

    /// Size of an entry. For project artifacts, "last modified" also takes work on the project itself into account.
    static func usage(of entry: Entry, home: URL) -> DiskUsage {
        if let preset = entry.presetUsage { return preset }
        var usage = DiskSize.measure(entry.url)
        for companion in entry.companions { usage.bytes += DiskSize.measure(companion).bytes }
        if entry.scope == .project,
           let activity = ProjectActivity.newest(in: entry.url.deletingLastPathComponent(), home: home) {
            usage.lastModified = max(usage.lastModified ?? .distantPast, activity)
        }
        // For apps and backups the date comes from metadata, not from the files inside.
        if let activity = entry.activityDate { usage.lastModified = activity }
        return usage
    }

    // MARK: - Blocking

    /// Rule-level blocking reasons (running apps/processes). `pgrep` is called once per rule.
    public static func ruleBlocks(for rules: [CleanupRule], snapshot: RunningSnapshot) -> [String: String] {
        var blocks: [String: String] = [:]
        for rule in rules {
            if let reason = RunningProbe.blockReason(for: rule, snapshot: snapshot) {
                blocks[rule.id] = reason
            }
        }
        return blocks
    }

    /// English "3 days" versus the Ukrainian abbreviation, which does not change with the number.
    private static func dayCount(_ n: Int) -> String {
        Loc.plural(n, en: (one: "\(n) day", other: "\(n) days"), uk: (one: "\(n) дн.", few: "\(n) дн.", many: "\(n) дн."))
    }

    /// Why this particular entry cannot be deleted right now (or `nil`).
    public static func blockReason(
        for entry: Entry, rule: CleanupRule, ruleBlock: String?, snapshot: RunningSnapshot, now: Date = Date()
    ) -> String? {
        if let locked = entry.lockedReason { return locked }
        if let ruleBlock { return ruleBlock }
        if let days = rule.protectRecentDays, let last = entry.measurement?.lastModified {
            let age = Int(now.timeIntervalSince(last) / 86_400)
            if age < days { return age == 0 ? L("Used today") : L("Used %@ ago", dayCount(age)) }
        }
        if rule.skipRunningAppCaches, snapshot.ownsCache(named: entry.ownerName ?? entry.name) {
            return L("App is running")
        }
        return nil
    }

    /// The "select by default or not" decision together with its reason, so the logic is visible in diagnostics.
    public struct DefaultDecision: Sendable, Equatable {
        public let selected: Bool
        public let reason: String
    }

    public static func defaultDecision(_ entry: Entry, rule: CleanupRule, now: Date = Date()) -> DefaultDecision {
        // Rules from the user's file are never selected automatically: only manually, after reviewing the list.
        if rule.isCustom { return DefaultDecision(selected: false, reason: L("custom rule: manual only")) }
        // Anything that needs a password is never selected automatically: we ask for the password only on request.
        if rule.requiresAdmin { return DefaultDecision(selected: false, reason: L("administrator password needed: manual only")) }
        // Personal files, backups and apps are selected by the user manually only.
        switch entry.scope {
        case .userFile: return DefaultDecision(selected: false, reason: L("personal files: manual only"))
        case .backup: return DefaultDecision(selected: false, reason: L("backup: manual only"))
        case .application: return DefaultDecision(selected: false, reason: L("app: manual only"))
        default: break
        }
        if let days = rule.autoSelectOlderThanDays {
            guard let last = entry.measurement?.lastModified else {
                return DefaultDecision(selected: false, reason: L("unknown when it last changed"))
            }
            let age = Int(now.timeIntervalSince(last) / 86_400)
            return age >= days
                ? DefaultDecision(selected: true, reason: L("not modified for %@ (at least %ld required)", dayCount(age), days))
                : DefaultDecision(selected: false, reason: L("activity %@ ago (at least %ld required)", dayCount(age), days))
        }
        return rule.risk == .safe
            ? DefaultDecision(selected: true, reason: L("safe cache"))
            : DefaultDecision(selected: false, reason: L("careful rule: manual only"))
    }

    /// Whether to select the entry by default after a scan.
    public static func isSelectedByDefault(_ entry: Entry, rule: CleanupRule, now: Date = Date()) -> Bool {
        defaultDecision(entry, rule: rule, now: now).selected
    }
}
