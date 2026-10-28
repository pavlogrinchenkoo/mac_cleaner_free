import Darwin
import Foundation

// MARK: - Карта зайнятого місця

public struct SurveyItem: Sendable {
    public let name: String
    public let bytes: Int64
    public let lastModified: Date?
    /// Розмір неповний (не встиг дорахувати): справжній більший.
    public let incomplete: Bool
    /// Пояснення (наприклад, чому не міряв).
    public let note: String?
    /// Найбільший вміст цього елемента (лише для дуже великих тек): щоб бачити, що всередині.
    public let children: [SurveyItem]

    public init(
        name: String, bytes: Int64, lastModified: Date?, incomplete: Bool = false, note: String? = nil,
        children: [SurveyItem] = []
    ) {
        self.name = name
        self.bytes = bytes
        self.lastModified = lastModified
        self.incomplete = incomplete
        self.note = note
        self.children = children
    }
}

public struct SurveySection: Sendable {
    public let title: String
    public let path: String
    /// Найбільші елементи, від більшого.
    public let items: [SurveyItem]
    /// Скільки елементів усього і скільки місця займають ті, що не потрапили в `items`.
    public let totalCount: Int
    public let restBytes: Int64
    /// Тека не прочиталась (наприклад, немає Full Disk Access).
    public let error: String?

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } + restBytes }
}

/// Тека, вміст якої розкладаємо за розміром.
public struct SurveyDirectory: Sendable {
    public let title: String
    public let url: URL
    /// Дочірні шляхи, які пропускаємо (вони розглядаються окремо).
    public let skip: Set<String>
    /// Дочірні шляхи, які показуємо, але не міряємо, з поясненням.
    public let unmeasured: [String: String]

    public init(title: String, url: URL, skip: Set<String> = [], unmeasured: [String: String] = [:]) {
        self.title = title
        self.url = url
        self.skip = skip
        self.unmeasured = unmeasured
    }
}

/// Розмір вмісту ключових папок: щоб побачити, що саме займає місце на чужому маці й написати правила.
/// Має жорсткі ліміти часу: діагностика ніколи не має «зависати».
public enum DiskSurvey {
    public static let topPerSection = 40
    public static let defaultItemBudget: TimeInterval = 20
    public static let defaultTotalBudget: TimeInterval = 150
    /// Теки більші за це розкриваємо ще на рівень углиб.
    public static let defaultDrillThreshold: Int64 = 1_000_000_000
    public static let drillItemsPerSection = 6
    public static let drillChildrenPerItem = 8
    public static let defaultDrillBudget: TimeInterval = 60
    /// Скільки рівнів углиб зазирати (1 = лише вміст великої теки, 2 = ще й вміст її найбільших дітей).
    public static let drillDepth = 3

    public static func directories(home: URL) -> [SurveyDirectory] {
        let library = home.appendingPathComponent("Library")
        let main: [(String, URL)] = [
            ("~/Library/Application Support", library.appendingPathComponent("Application Support")),
            ("~/Library/Caches", library.appendingPathComponent("Caches")),
            ("~/Library/Containers", library.appendingPathComponent("Containers")),
            ("~/Library/Group Containers", library.appendingPathComponent("Group Containers")),
            ("~/Library/Logs", library.appendingPathComponent("Logs")),
            ("~/Downloads", home.appendingPathComponent("Downloads")),
            ("~/Desktop", home.appendingPathComponent("Desktop")),
            ("~/Documents", home.appendingPathComponent("Documents")),
            ("~/Movies", home.appendingPathComponent("Movies")),
            ("~/Music", home.appendingPathComponent("Music")),
            ("~/Pictures", home.appendingPathComponent("Pictures")),
            ("/Applications", URL(fileURLWithPath: "/Applications")),
            ("/Library", URL(fileURLWithPath: "/Library")),
        ]
        // «Решта» не повторює вже розгорнуті теки.
        let expanded = Set(main.map { $0.1.standardizedFileURL.path })
        let cloud = [
            library.appendingPathComponent("Mobile Documents").path: L("iCloud Drive: contents not measured (reading may hang)"),
            library.appendingPathComponent("CloudStorage").path: L("cloud storage (Google Drive etc.): contents not measured"),
        ]
        return main.map { SurveyDirectory(title: $0.0, url: $0.1) } + [
            SurveyDirectory(title: L("~/Library (the rest)"), url: library, skip: expanded, unmeasured: cloud),
            SurveyDirectory(title: L("~ (the rest of the home folder)"), url: home, skip: expanded.union([library.path])),
        ]
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var results: [[SurveyItem]]
        private var finished = Set<Int>()
        private var sealed = false
        private var done = 0
        init(count: Int) { results = Array(repeating: [], count: count) }

        /// Повертає кількість завершених або `nil`, якщо збір уже закрито.
        func add(_ item: SurveyItem, section: Int, job: Int) -> Int? {
            lock.lock(); defer { lock.unlock() }
            guard !sealed else { return nil }
            results[section].append(item)
            finished.insert(job)
            done += 1
            return done
        }

        func seal() -> Set<Int> {
            lock.lock(); defer { lock.unlock() }
            sealed = true
            return finished
        }

        func snapshot() -> [[SurveyItem]] {
            lock.lock(); defer { lock.unlock() }
            return results
        }
    }

    public static func run(
        home: URL,
        directories override: [SurveyDirectory]? = nil,
        itemBudget: TimeInterval = defaultItemBudget,
        totalBudget: TimeInterval = defaultTotalBudget,
        drillThreshold: Int64 = defaultDrillThreshold,
        drillBudget: TimeInterval = defaultDrillBudget,
        progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in },
        isCancelled: @Sendable () -> Bool = { false }
    ) -> [SurveySection] {
        let directories = override ?? directories(home: home)

        struct Job: Sendable { let section: Int; let name: String; let url: URL; let note: String? }
        var jobs: [Job] = []
        var errors: [Int: String] = [:]
        for (index, directory) in directories.enumerated() {
            do {
                let names = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
                for name in names {
                    let child = directory.url.appendingPathComponent(name)
                    let path = child.standardizedFileURL.path
                    if directory.skip.contains(path) { continue }
                    jobs.append(Job(section: index, name: name, url: child, note: directory.unmeasured[path]))
                }
            } catch {
                if (error as NSError).code != NSFileReadNoSuchFileError {
                    errors[index] = FullDiskAccess.isDenied(error) ? L("no access (Full Disk Access required)") : error.localizedDescription
                }
            }
        }

        let collector = Collector(count: directories.count)
        let allJobs = jobs
        let total = allJobs.count
        let queue = DispatchQueue(label: "cleaner.survey", qos: .userInitiated, attributes: .concurrent)
        let group = DispatchGroup()
        let slots = DispatchSemaphore(value: 6)
        let totalDeadline = Date().addingTimeInterval(totalBudget)

        // Власний пул замість `concurrentPerform`: так можна припинити чекання, навіть якщо потік застряг у ядрі
        // (наприклад, на файловому провайдері iCloud).
        var next = 0
        while next < total {
            if isCancelled() || Date() >= totalDeadline { break }
            if slots.wait(timeout: .now() + 0.5) == .timedOut { continue }
            let index = next
            next += 1
            let job = allJobs[index]
            group.enter()
            queue.async {
                defer { slots.signal(); group.leave() }
                let item: SurveyItem
                if let note = job.note {
                    item = SurveyItem(name: job.name, bytes: 0, lastModified: nil, note: note)
                } else {
                    let usage = DiskSize.measure(job.url, deadline: Date().addingTimeInterval(itemBudget))
                    item = SurveyItem(name: job.name, bytes: usage.bytes, lastModified: usage.lastModified, incomplete: usage.timedOut)
                }
                if let done = collector.add(item, section: job.section, job: index), done % 5 == 0 || done == total {
                    progress(done, total)
                }
            }
        }
        // Чекаємо на завершення, але не довше за залишок бюджету (+ невеликий запас на добіг).
        _ = group.wait(timeout: .now() + max(0, totalDeadline.timeIntervalSinceNow) + 3)
        let finished = collector.seal()

        // Те, що не встигли чи перервали, лишаємо у звіті з позначкою, а не губимо.
        var results = collector.snapshot()
        for (index, job) in allJobs.enumerated() where !finished.contains(index) {
            results[job.section].append(SurveyItem(name: job.name, bytes: 0, lastModified: nil, incomplete: true, note: L("did not finish (interrupted or hung)")))
        }
        // Друга фаза: що всередині найбільших тек (наприклад, чому «Preferences» важить 20 ГБ).
        var children: [String: [SurveyItem]] = [:]
        if drillThreshold > 0, !isCancelled() {
            struct Drill: Sendable { let key: String; let url: URL }
            var targets: [Drill] = []
            for (index, directory) in directories.enumerated() {
                // Усередині .app (Contents) заглядати нема сенсу.
                let big = results[index].filter { $0.bytes >= drillThreshold && $0.note == nil && !$0.incomplete && !$0.name.hasSuffix(".app") }
                    .sorted { $0.bytes > $1.bytes }.prefix(drillItemsPerSection)
                for item in big {
                    targets.append(Drill(key: "\(index)/\(item.name)", url: directory.url.appendingPathComponent(item.name)))
                }
            }
            let perTargetBudget = drillBudget / Double(max(targets.count, 1)) + 5

            /// Вміст теки з розкриттям найбільших дітей, поки не вичерпано глибину.
            func expand(_ url: URL, depth: Int) -> [SurveyItem] {
                guard !isCancelled(), let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
                let urls = names.map { url.appendingPathComponent($0) }.filter { !DiskSize.isCloudProviderDirectory($0.path) }
                let usages = measureAll(urls, itemBudget: itemBudget, totalBudget: perTargetBudget, isCancelled: isCancelled)
                var items = zip(urls, usages).map { url, usage in
                    SurveyItem(name: url.lastPathComponent, bytes: usage?.bytes ?? 0, lastModified: usage?.lastModified,
                               incomplete: usage == nil || usage?.timedOut == true)
                }.sorted { $0.bytes > $1.bytes }
                items = Array(items.prefix(drillChildrenPerItem))
                guard depth < drillDepth else { return items }
                // Найбільші діти (від порога) розкриваємо ще на рівень.
                var expanded = 0
                for index in items.indices where items[index].bytes >= drillThreshold && !items[index].incomplete
                    && !items[index].name.hasSuffix(".app") && expanded < 5 {
                    expanded += 1
                    let inner = expand(url.appendingPathComponent(items[index].name), depth: depth + 1)
                    let item = items[index]
                    items[index] = SurveyItem(name: item.name, bytes: item.bytes, lastModified: item.lastModified,
                                              incomplete: item.incomplete, note: item.note, children: inner)
                }
                return items
            }

            for drill in targets where !isCancelled() {
                children[drill.key] = expand(drill.url, depth: 1)
            }
        }

        progress(total, total)

        return directories.enumerated().map { index, directory in
            let items = results[index].sorted { $0.bytes > $1.bytes }.map { item -> SurveyItem in
                guard let inner = children["\(index)/\(item.name)"] else { return item }
                return SurveyItem(name: item.name, bytes: item.bytes, lastModified: item.lastModified,
                                  incomplete: item.incomplete, note: item.note, children: inner)
            }
            // Найбільші + усе з поясненням чи недораховане (воно має нульовий розмір і інакше випало б із топу).
            let beyond = items.dropFirst(topPerSection)
            let pinned = beyond.filter { $0.note != nil || $0.incomplete }
            let top = Array(items.prefix(topPerSection)) + pinned
            let rest = beyond.filter { $0.note == nil && !$0.incomplete }.reduce(Int64(0)) { $0 + $1.bytes }
            return SurveySection(
                title: directory.title, path: directory.url.path, items: top,
                totalCount: items.count, restBytes: rest, error: errors[index])
        }
    }

    /// Міряє кілька шляхів у власному пулі з бюджетом часу. `nil` у результаті = не встиг.
    private static func measureAll(
        _ urls: [URL], itemBudget: TimeInterval, totalBudget: TimeInterval, isCancelled: @Sendable () -> Bool
    ) -> [DiskUsage?] {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [DiskUsage?]
            private var sealed = false
            init(count: Int) { values = Array(repeating: nil, count: count) }
            func set(_ value: DiskUsage, at index: Int) { lock.lock(); if !sealed { values[index] = value }; lock.unlock() }
            func seal() -> [DiskUsage?] { lock.lock(); defer { lock.unlock() }; sealed = true; return values }
        }
        let box = Box(count: urls.count)
        let queue = DispatchQueue(label: "cleaner.survey.drill", qos: .userInitiated, attributes: .concurrent)
        let group = DispatchGroup()
        let slots = DispatchSemaphore(value: 6)
        let deadline = Date().addingTimeInterval(totalBudget)
        var next = 0
        while next < urls.count {
            if isCancelled() || Date() >= deadline { break }
            if slots.wait(timeout: .now() + 0.5) == .timedOut { continue }
            let index = next
            next += 1
            let url = urls[index]
            group.enter()
            queue.async {
                defer { slots.signal(); group.leave() }
                box.set(DiskSize.measure(url, deadline: Date().addingTimeInterval(itemBudget)), at: index)
            }
        }
        _ = group.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow) + 3)
        return box.seal()
    }
}

// MARK: - Звіт

public struct DiagnosticInput: Sendable {
    public var appVersion: String
    public var generatedAt: Date
    public var dryRun: Bool
    public var macOSVersion: String
    public var architecture: String
    public var fullDiskAccess: Bool
    public var disk: DiskInfo?
    public var projectRoots: [URL]
    public var fileSettings: FileScanSettings?
    public var groups: [CleanupGroup]
    public var results: [RuleResult]
    public var selectedIDs: Set<String>
    /// Елементи, які користувач чіпав руками (вибрав або зняв): щоб відрізнити від автоматичного вибору.
    public var manualIDs: Set<String>
    public var ruleBlocks: [String: String]
    public var blockReason: @Sendable (Entry, CleanupRule) -> String?
    public var report: CleanReport?
    public var apps: [DiagnosticApp]
    public var survey: [SurveySection]
    public var home: URL

    public init(
        appVersion: String, generatedAt: Date = Date(), dryRun: Bool, macOSVersion: String, architecture: String,
        fullDiskAccess: Bool, disk: DiskInfo?, projectRoots: [URL], fileSettings: FileScanSettings?,
        groups: [CleanupGroup], results: [RuleResult], selectedIDs: Set<String>, manualIDs: Set<String> = [],
        ruleBlocks: [String: String],
        blockReason: @escaping @Sendable (Entry, CleanupRule) -> String?, report: CleanReport? = nil,
        apps: [DiagnosticApp], survey: [SurveySection], home: URL
    ) {
        self.appVersion = appVersion
        self.generatedAt = generatedAt
        self.dryRun = dryRun
        self.macOSVersion = macOSVersion
        self.architecture = architecture
        self.fullDiskAccess = fullDiskAccess
        self.disk = disk
        self.projectRoots = projectRoots
        self.fileSettings = fileSettings
        self.groups = groups
        self.results = results
        self.selectedIDs = selectedIDs
        self.manualIDs = manualIDs
        self.ruleBlocks = ruleBlocks
        self.blockReason = blockReason
        self.report = report
        self.apps = apps
        self.survey = survey
        self.home = home
    }
}

public struct DiagnosticApp: Sendable {
    public let path: String
    public let bundleID: String
    public let version: String
}

/// Markers and headings of the report that other code (the self-check, the tests) searches for. They live in one
/// place so the report and its readers always agree, whatever the interface language is.
public enum DiagnosticMarkers {
    public static var auto: String { L("[✓ auto]") }
    public static var manualOn: String { L("[✓ MANUAL]") }
    public static var manualOff: String { L("[✗ MANUAL OFF]") }
    /// Not translated: these three are the same in every language.
    public static var unexplained: String { "[✓ ???]" }
    public static var notSelected: String { "[  ]" }
    public static var blocked: String { "[🔒]" }

    public static var summaryTitle: String { L("SUMMARY") }
    public static var summaryHeader: String { "== \(summaryTitle) ==" }
    public static var surveyTitle: String { L("DISK USAGE MAP") }
    public static var surveyHeader: String { "== \(surveyTitle) ==" }
    public static var installedAppsTitle: String { L("INSTALLED APPS") }
    public static func installedAppsHeader(count: Int) -> String { "== \(installedAppsTitle) (\(count)) ==" }
    /// A phrase of the "selected for an unknown reason" summary line (the line is written in `render`).
    public static var unexplainedPhrase: String { L("for an UNKNOWN reason") }
}

public enum DiagnosticReport {
    /// Встановлені програми (до двох рівнів вглиб: Adobe кладе програми в підпапки) без розкриття вмісту.
    public static func installedApps(roots: [URL]) -> [DiagnosticApp] {
        var apps: [DiagnosticApp] = []
        for root in roots {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names {
                let url = root.appendingPathComponent(name)
                if name.hasSuffix(".app") {
                    apps.append(app(at: url))
                } else if let inner = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
                    for child in inner where child.hasSuffix(".app") { apps.append(app(at: url.appendingPathComponent(child))) }
                }
            }
        }
        return apps.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func app(at url: URL) -> DiagnosticApp {
        var id = "?", version = ""
        if let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
           let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
            id = (info["CFBundleIdentifier"] as? String) ?? "?"
            version = (info["CFBundleShortVersionString"] as? String) ?? ""
        }
        return DiagnosticApp(path: url.path, bundleID: id, version: version)
    }

    public static func fileName(for date: Date, dryRun: Bool) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        return "\(dryRun ? "dryrun" : "scan")-\(stamp.string(from: date)).txt"
    }

    /// Зберігає звіт поруч з іншими логами. Повертає шлях до файлу.
    public static func write(_ text: String, home: URL, date: Date = Date(), dryRun: Bool = true) -> URL? {
        let directory = home.appendingPathComponent("Library/Application Support/Cleaner/logs")
        let url = directory.appendingPathComponent(fileName(for: date, dryRun: dryRun))
        do {
            try PrivateStorage.write(text, to: url)
            return url
        } catch {
            return nil
        }
    }

    private static let maxEntriesPerRule = 600

    /// Останній прохід по готовому звіту: прибирає те, що ідентифікує людину чи її пристрої, навіть якщо воно
    /// потрапило в текст не через `short()`: ім'я користувача в `/Users/<ім'я>/…` та ідентифікатори пристроїв iPhone/iPad
    /// (UDID резервних копій: `00008110-001A2B3C4D5E6F78` або 40 hex-символів).
    static func redactPersonalIdentifiers(_ text: String) -> String {
        let rules: [(pattern: String, template: String)] = [
            (#"/Users/(?!Shared(?:/|\s|$))[^/\s«»]+"#, "/Users/<user>"),
            (#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b"#, "<device-id>"),
            (#"\b[0-9a-f]{40}\b"#, "<device-id>"),
        ]
        var result = text
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: rule.template)
        }
        return result
    }

    public static func render(_ input: DiagnosticInput) -> String {
        var out: [String] = []
        let home = input.home
        func size(_ bytes: Int64) -> String { Loc.bytes(bytes) }
        func short(_ path: String) -> String { path.hasPrefix(home.path) ? "~" + path.dropFirst(home.path.count) : path }
        func days(_ date: Date?) -> String {
            guard let date else { return "?" }
            let d = Int(input.generatedAt.timeIntervalSince(date) / 86_400)
            return d <= 0 ? L("today") : L("%ld days", d)
        }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        out.append(input.dryRun ? L("CLEANER — DIAGNOSTICS (dry run)") : L("CLEANER — DIAGNOSTICS (scan)"))
        out.append(L("This file contains names and paths of files and apps from this Mac. Please review it before sending."))
        out.append("")
        out.append(L("Date: %@", stamp.string(from: input.generatedAt)))
        out.append(L("Cleaner: %@   macOS: %@   Architecture: %@", input.appVersion, input.macOSVersion, input.architecture))
        out.append(input.fullDiskAccess ? L("Full Disk Access: granted") : L("Full Disk Access: not granted"))
        if let disk = input.disk {
            out.append(L("Disk: %@ free of %@", size(disk.freeBytes), size(disk.totalBytes)))
        }
        out.append(input.projectRoots.isEmpty
            ? L("Project folders: none")
            : L("Project folders: %@", input.projectRoots.map { short($0.path) }.joined(separator: ", ")))
        if let files = input.fileSettings {
            out.append(L("File search: %@", files.roots.map { short($0.path) }.joined(separator: ", ")))
            out.append(L("Thresholds: large from %@, duplicates from %@, installers from %@",
                         size(files.minLargeBytes), size(files.minDuplicateBytes), size(files.minInstallerBytes)))
        }

        // --- Класифікація кожного елемента ---
        enum Status { case blocked(String), auto, manualOn, manualOff, notSelected, unexplained }
        struct Row { let entry: Entry; let rule: CleanupRule; let status: Status; let decision: DiskScanner.DefaultDecision }
        var rows: [Row] = []
        for result in input.results {
            for entry in result.entries where entry.bytes > 0 || entry.lockedReason != nil {
                let decision = DiskScanner.defaultDecision(entry, rule: result.rule, now: input.generatedAt)
                let manual = input.manualIDs.contains(entry.id)
                let selected = input.selectedIDs.contains(entry.id)
                // Клас визначає, чим стан ВІДРІЗНЯЄТЬСЯ від автоматичного: клік туди й назад нічого не змінює.
                let status: Status
                if let reason = input.blockReason(entry, result.rule) {
                    status = .blocked(reason)
                } else if selected {
                    // Вибрано, хоча програма сама б не вибрала: має бути слід кліку. Якщо його немає, це помилка.
                    status = decision.selected ? .auto : (manual ? .manualOn : .unexplained)
                } else {
                    status = decision.selected && manual ? .manualOff : .notSelected
                }
                rows.append(Row(entry: entry, rule: result.rule, status: status, decision: decision))
            }
        }
        func sum(_ rows: [Row]) -> Int64 { rows.reduce(0) { $0 + $1.entry.bytes } }
        func isActive(_ status: Status) -> Bool {
            switch status { case .auto, .manualOn: true; default: false }
        }
        let auto = rows.filter { if case .auto = $0.status { true } else { false } }
        let manualOn = rows.filter { if case .manualOn = $0.status { true } else { false } }
        let manualOff = rows.filter { if case .manualOff = $0.status { true } else { false } }
        let notSelected = rows.filter { if case .notSelected = $0.status { true } else { false } }
        let blocked = rows.filter { if case .blocked = $0.status { true } else { false } }
        let unexplained = rows.filter { if case .unexplained = $0.status { true } else { false } }
        let active = rows.filter { isActive($0.status) || { if case .unexplained = $0.status { return true } else { return false } }($0) }
        let activeTrash = active.filter { $0.entry.action == .trashPaths }
        let activeDelete = active.filter { $0.entry.action != .trashPaths }

        // --- Підсумок ---
        out.append("")
        out.append(DiagnosticMarkers.summaryHeader)
        out.append(L("Found %ld item(s) (%@) in %ld rule(s).", rows.count, size(sum(rows)), input.results.filter { !$0.entries.isEmpty }.count))
        out.append(L("Selected AUTOMATICALLY (by default): %ld item(s), %@.", auto.count, size(sum(auto))))
        out.append(L("Added MANUALLY by the user: %ld item(s), %@.", manualOn.count, size(sum(manualOn))))
        out.append(L("Unselected MANUALLY (the app would have selected it): %ld item(s), %@.", manualOff.count, size(sum(manualOff))))
        if !unexplained.isEmpty {
            out.append(L("⚠︎ Selected for an UNKNOWN reason (neither by default nor by a click): %ld item(s), %@. This is an app bug.",
                         unexplained.count, size(sum(unexplained))))
        }
        out.append(L("Not selected because manual-only: %ld item(s), %@.", notSelected.count, size(sum(notSelected))))
        func grouped(_ rows: [Row], reason: (Row) -> String) {
            let byReason = Dictionary(grouping: rows, by: reason)
            for (text, items) in byReason.sorted(by: { sum($0.value) > sum($1.value) }) {
                out.append(L("    %@: %ld item(s), %@", text, items.count, size(sum(items))))
            }
        }
        grouped(notSelected) { $0.decision.reason }
        out.append(L("BLOCKED (cannot be selected right now): %ld item(s), %@.", blocked.count, size(sum(blocked))))
        grouped(blocked) { row in
            if case .blocked(let reason) = row.status { return reason }
            return ""
        }
        out.append(L("TOTAL SELECTED NOW: %ld item(s): delete permanently %@, move to Trash %@.",
                         active.count, size(sum(activeDelete)), size(sum(activeTrash))))
        if let report = input.report {
            let freed = size(report.freedBytes), trashed = size(report.trashedBytes)
            out.append(input.dryRun
                ? L("Would be done: freed %@, to Trash %@; skipped %ld, errors %ld.", freed, trashed, report.skipped.count, report.failures.count)
                : L("Done: freed %@, to Trash %@; skipped %ld, errors %ld.", freed, trashed, report.skipped.count, report.failures.count))
            for item in report.skipped.prefix(100) {
                if case .skipped(let reason) = item.outcome { out.append(L("  skipped: %@ — %@", short(item.path), reason)) }
            }
            for item in report.failures.prefix(100) {
                if case .failed(let reason) = item.outcome { out.append(L("  error: %@ — %@", short(item.path), reason)) }
            }
        }

        // --- Знайдене по групах ---
        let rowsByEntry = Dictionary(rows.map { ($0.entry.id, $0) }, uniquingKeysWith: { first, _ in first })
        out.append("")
        out.append(L("== FOUND (EVERYTHING the app saw) =="))
        out.append(L("Legend:"))
        // Пояснення починаються з однієї колонки; емодзі займає два знаки.
        func legend(_ marker: String, _ meaning: String) {
            let width = marker.reduce(0) { $0 + (($1.unicodeScalars.first?.value ?? 0) >= 0x1F000 ? 2 : 1) }
            out.append("  " + marker + String(repeating: " ", count: max(1, 20 - width)) + meaning)
        }
        legend(DiagnosticMarkers.auto, L("selected by the app by default"))
        legend(DiagnosticMarkers.manualOn, L("selected by the user (the app would not have selected it)"))
        legend(DiagnosticMarkers.manualOff, L("the app would have selected it, but the user unselected it"))
        legend(DiagnosticMarkers.notSelected, L("not selected (manual-only by default; the reason is in the rule header)"))
        legend(DiagnosticMarkers.unexplained, L("selected, but neither by default nor by a click (this would be an app bug)"))
        legend(DiagnosticMarkers.blocked, L("blocked: cannot be selected right now (reason given: app is running, latest version…)"))
        out.append(L("Then: size, when last used/modified, path."))
        for group in input.groups {
            let results = input.results.filter { $0.rule.group == group.id }
            let visible = results.filter { $0.accessError != nil || $0.entries.contains { $0.bytes > 0 || $0.lockedReason != nil } }
            if visible.isEmpty { continue }
            out.append("")
            out.append("### \(group.title) [\(group.id)]")
            for result in visible {
                let rule = result.rule
                let total = result.entries.reduce(Int64(0)) { $0 + $1.bytes }
                var flags: [String] = [rule.risk == .safe ? L("safe to remove") : L("remove with care")]
                if rule.moveToTrash { flags.append(L("→ Trash")) }
                if rule.requiresAdmin { flags.append(L("admin password")) }
                if !rule.bulkSelectable { flags.append(L("“select all” disabled")) }
                out.append("")
                out.append("\(rule.title) [\(rule.id)] — \(size(total)) (\(flags.joined(separator: ", ")))")
                if let first = result.entries.first {
                    let policy = DiskScanner.defaultDecision(first, rule: rule, now: input.generatedAt)
                    if rule.autoSelectOlderThanDays != nil {
                        out.append(L("  auto-select: only what has not changed for %ld+ days", rule.autoSelectOlderThanDays!))
                    } else {
                        out.append(policy.selected
                            ? L("  auto-select: yes (%@)", policy.reason)
                            : L("  auto-select: no (%@)", policy.reason))
                    }
                }
                if let block = input.ruleBlocks[rule.id] { out.append(L("  blocked by the rule: %@", block)) }
                if let error = result.accessError { out.append("  ⚠︎ \(error)") }

                let entries = result.entries.filter { $0.bytes > 0 || $0.lockedReason != nil }.sorted { $0.bytes > $1.bytes }
                for entry in entries.prefix(maxEntriesPerRule) {
                    guard let row = rowsByEntry[entry.id] else { continue }
                    let mark: String
                    var why = ""
                    switch row.status {
                    case .blocked(let reason): mark = DiagnosticMarkers.blocked; why = reason
                    case .auto: mark = DiagnosticMarkers.auto
                    case .manualOn: mark = DiagnosticMarkers.manualOn
                    case .manualOff: mark = DiagnosticMarkers.manualOff
                    case .unexplained: mark = DiagnosticMarkers.unexplained
                    case .notSelected: mark = DiagnosticMarkers.notSelected
                        // Для правил із порогом давності причина різна в кожного елемента.
                        if rule.autoSelectOlderThanDays != nil { why = row.decision.reason }
                    }
                    // Резервну копію iPhone не називаємо ні іменем пристрою, ні його UDID (теку): це ідентифікує людину.
                    let isBackup = entry.scope == .backup
                    let shownPath = isBackup ? short(entry.url.deletingLastPathComponent().path) + "/<backup>" : short(entry.url.path)
                    var line = "  \(mark) \(size(entry.bytes))  \(days(entry.measurement?.lastModified))  \(shownPath)"
                    if !isBackup, entry.name != entry.url.lastPathComponent { line += "  «\(entry.name)»" }
                    if let sub = entry.subtitle, !sub.isEmpty { line += "  · \(sub)" }
                    if !entry.companions.isEmpty { line += L("  (+%ld paths)", entry.companions.count) }
                    if !why.isEmpty { line += "  · \(why)" }
                    out.append(line)
                }
                if entries.count > maxEntriesPerRule {
                    let rest = entries.dropFirst(maxEntriesPerRule).reduce(Int64(0)) { $0 + $1.bytes }
                    out.append(L("  … %ld more item(s) (%@)", entries.count - maxEntriesPerRule, size(rest)))
                }
            }
        }

        // --- Програми ---
        out.append("")
        out.append(DiagnosticMarkers.installedAppsHeader(count: input.apps.count))
        for app in input.apps {
            out.append("  \(short(app.path))  \(app.bundleID)  \(app.version)")
        }

        // --- Карта місця ---
        out.append("")
        out.append(DiagnosticMarkers.surveyHeader)
        out.append(L("Largest items in key folders (to find what else can be cleaned)."))
        let unfinished = input.survey.flatMap(\.items).filter(\.incomplete).count
        if unfinished > 0 {
            out.append(L("⚠︎ Not all sizes were fully measured (%ld): marked with “≥”. These are very large folders, or the diagnostic was interrupted.", unfinished))
        }
        for section in input.survey {
            out.append("")
            out.append(L("### %@ — %@, items: %ld", section.title, size(section.totalBytes), section.totalCount))
            if let error = section.error { out.append("  ⚠︎ \(error)") }
            for item in section.items where item.bytes >= 1_000_000 || item.incomplete || item.note != nil {
                let amount = item.incomplete ? "≥ \(size(item.bytes))" : size(item.bytes)
                var line = "  \(amount)  \(item.lastModified == nil ? "" : days(item.lastModified))  \(item.name)"
                if let note = item.note { line += "  · \(note)" }
                out.append(line)
                func renderChildren(_ children: [SurveyItem], indent: String) {
                    for child in children where child.bytes >= 100_000_000 || child.incomplete {
                        let childAmount = child.incomplete ? "≥ \(size(child.bytes))" : size(child.bytes)
                        out.append("\(indent)└ \(childAmount)  \(child.name)")
                        renderChildren(child.children, indent: indent + "    ")
                    }
                }
                renderChildren(item.children, indent: "      ")
            }
            if section.restBytes > 0 { out.append(L("  … the rest of the smaller ones: %@", size(section.restBytes))) }
        }
        return redactPersonalIdentifiers(out.joined(separator: "\n")) + "\n"
    }
}

/// Дані про систему для шапки звіту.
public enum SystemDescription {
    public static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    public static var architecture: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    public static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
