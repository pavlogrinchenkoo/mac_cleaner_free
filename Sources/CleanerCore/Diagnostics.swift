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
            library.appendingPathComponent("Mobile Documents").path: "iCloud Drive: вміст не міряю (читання може зависати)",
            library.appendingPathComponent("CloudStorage").path: "хмарні сховища (Google Drive тощо): вміст не міряю",
        ]
        return main.map { SurveyDirectory(title: $0.0, url: $0.1) } + [
            SurveyDirectory(title: "~/Library (решта)", url: library, skip: expanded, unmeasured: cloud),
            SurveyDirectory(title: "~ (решта домашньої папки)", url: home, skip: expanded.union([library.path])),
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
                    errors[index] = FullDiskAccess.isDenied(error) ? "немає доступу (потрібен Full Disk Access)" : error.localizedDescription
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
            results[job.section].append(SurveyItem(name: job.name, bytes: 0, lastModified: nil, incomplete: true, note: "не встиг (перервано чи завис)"))
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
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static let maxEntriesPerRule = 600

    public static func render(_ input: DiagnosticInput) -> String {
        var out: [String] = []
        let home = input.home
        func size(_ bytes: Int64) -> String { bytes <= 0 ? "0 КБ" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        func short(_ path: String) -> String { path.hasPrefix(home.path) ? "~" + path.dropFirst(home.path.count) : path }
        func days(_ date: Date?) -> String {
            guard let date else { return "?" }
            let d = Int(input.generatedAt.timeIntervalSince(date) / 86_400)
            return d <= 0 ? "сьогодні" : "\(d) дн."
        }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        out.append("CLEANER — ДІАГНОСТИКА (\(input.dryRun ? "пробний запуск" : "сканування"))")
        out.append("Цей файл містить назви й шляхи файлів та програм з цього Mac. Перегляньте його перед відправкою.")
        out.append("")
        out.append("Дата: \(stamp.string(from: input.generatedAt))")
        out.append("Cleaner: \(input.appVersion)   macOS: \(input.macOSVersion)   Архітектура: \(input.architecture)")
        out.append("Full Disk Access: \(input.fullDiskAccess ? "є" : "немає")")
        if let disk = input.disk {
            out.append("Диск: вільно \(size(disk.freeBytes)) з \(size(disk.totalBytes))")
        }
        out.append("Папки проєктів: \(input.projectRoots.isEmpty ? "немає" : input.projectRoots.map { short($0.path) }.joined(separator: ", "))")
        if let files = input.fileSettings {
            out.append("Пошук файлів: \(files.roots.map { short($0.path) }.joined(separator: ", "))")
            out.append("Пороги: великі від \(size(files.minLargeBytes)), дублікати від \(size(files.minDuplicateBytes)), інсталятори від \(size(files.minInstallerBytes))")
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
        out.append("== ПІДСУМОК ==")
        out.append("Знайдено \(rows.count) елементів (\(size(sum(rows)))) у \(input.results.filter { !$0.entries.isEmpty }.count) правилах.")
        out.append("Вибрано АВТОМАТИЧНО (за замовчуванням): \(auto.count) елементів, \(size(sum(auto))).")
        out.append("Додано ВРУЧНУ користувачем: \(manualOn.count) елементів, \(size(sum(manualOn))).")
        out.append("Знято ВРУЧНУ (програма вибрала б сама): \(manualOff.count) елементів, \(size(sum(manualOff))).")
        if !unexplained.isEmpty {
            out.append("⚠︎ Вибрано з НЕВІДОМОЇ причини (ні за замовчуванням, ні кліком): \(unexplained.count) елементів, \(size(sum(unexplained))). Це помилка програми.")
        }
        out.append("Не вибрано, бо лише вручну: \(notSelected.count) елементів, \(size(sum(notSelected))).")
        func grouped(_ rows: [Row], reason: (Row) -> String) {
            let byReason = Dictionary(grouping: rows, by: reason)
            for (text, items) in byReason.sorted(by: { sum($0.value) > sum($1.value) }) {
                out.append("    \(text): \(items.count) елементів, \(size(sum(items)))")
            }
        }
        grouped(notSelected) { $0.decision.reason }
        out.append("ЗАБЛОКОВАНО (зараз не можна вибрати): \(blocked.count) елементів, \(size(sum(blocked))).")
        grouped(blocked) { row in
            if case .blocked(let reason) = row.status { return reason }
            return ""
        }
        out.append("РАЗОМ ВИБРАНО ЗАРАЗ: \(active.count) елементів: видалити назовсім \(size(sum(activeDelete))), перемістити в Кошик \(size(sum(activeTrash))).")
        if let report = input.report {
            let kind = input.dryRun ? "Було б" : "Зроблено"
            out.append("\(kind): звільнено \(size(report.freedBytes)), у Кошик \(size(report.trashedBytes)); пропущено \(report.skipped.count), помилок \(report.failures.count).")
            for item in report.skipped.prefix(100) {
                if case .skipped(let reason) = item.outcome { out.append("  пропущено: \(short(item.path)) — \(reason)") }
            }
            for item in report.failures.prefix(100) {
                if case .failed(let reason) = item.outcome { out.append("  помилка: \(short(item.path)) — \(reason)") }
            }
        }

        // --- Знайдене по групах ---
        let rowsByEntry = Dictionary(rows.map { ($0.entry.id, $0) }, uniquingKeysWith: { first, _ in first })
        out.append("")
        out.append("== ЗНАЙДЕНЕ (УСЕ, що програма побачила) ==")
        out.append("Позначки:")
        out.append("  [✓ авто]            вибрано програмою за замовчуванням")
        out.append("  [✓ ВРУЧНУ]          вибрав користувач (програма сама б не вибрала)")
        out.append("  [✗ ЗНЯТО ВРУЧНУ]    програма вибрала б сама, але користувач зняв")
        out.append("  [  ]                не вибрано (за замовчуванням тут лише вручну; причина в заголовку правила)")
        out.append("  [✓ ???]             вибрано, але ні за замовчуванням, ні кліком (це була б помилка програми)")
        out.append("  [🔒]                заблоковано: зараз вибрати не можна (причина вказана: програма запущена, остання версія…)")
        out.append("Далі: розмір, коли востаннє використовувалось/змінювалось, шлях.")
        for group in input.groups {
            let results = input.results.filter { $0.rule.group == group.id }
            let visible = results.filter { $0.accessError != nil || $0.entries.contains { $0.bytes > 0 || $0.lockedReason != nil } }
            if visible.isEmpty { continue }
            out.append("")
            out.append("### \(group.title) [\(group.id)]")
            for result in visible {
                let rule = result.rule
                let total = result.entries.reduce(Int64(0)) { $0 + $1.bytes }
                var flags: [String] = [rule.risk == .safe ? "безпечно" : "обережно"]
                if rule.moveToTrash { flags.append("→ Кошик") }
                if rule.requiresAdmin { flags.append("пароль") }
                if !rule.bulkSelectable { flags.append("«вибрати все» вимкнено") }
                out.append("")
                out.append("\(rule.title) [\(rule.id)] — \(size(total)) (\(flags.joined(separator: ", ")))")
                if let first = result.entries.first {
                    let policy = DiskScanner.defaultDecision(first, rule: rule, now: input.generatedAt)
                    if rule.autoSelectOlderThanDays != nil {
                        out.append("  автовибір: лише те, що не змінювалось \(rule.autoSelectOlderThanDays!)+ днів")
                    } else {
                        out.append("  автовибір: \(policy.selected ? "так" : "ні") (\(policy.reason))")
                    }
                }
                if let block = input.ruleBlocks[rule.id] { out.append("  заблоковано правилом: \(block)") }
                if let error = result.accessError { out.append("  ⚠︎ \(error)") }

                let entries = result.entries.filter { $0.bytes > 0 || $0.lockedReason != nil }.sorted { $0.bytes > $1.bytes }
                for entry in entries.prefix(maxEntriesPerRule) {
                    guard let row = rowsByEntry[entry.id] else { continue }
                    let mark: String
                    var why = ""
                    switch row.status {
                    case .blocked(let reason): mark = "[🔒]"; why = reason
                    case .auto: mark = "[✓ авто]"
                    case .manualOn: mark = "[✓ ВРУЧНУ]"
                    case .manualOff: mark = "[✗ ЗНЯТО ВРУЧНУ]"
                    case .unexplained: mark = "[✓ ???]"
                    case .notSelected: mark = "[  ]"
                        // Для правил із порогом давності причина різна в кожного елемента.
                        if rule.autoSelectOlderThanDays != nil { why = row.decision.reason }
                    }
                    var line = "  \(mark) \(size(entry.bytes))  \(days(entry.measurement?.lastModified))  \(short(entry.url.path))"
                    if entry.name != entry.url.lastPathComponent { line += "  «\(entry.name)»" }
                    if let sub = entry.subtitle, !sub.isEmpty { line += "  · \(sub)" }
                    if !entry.companions.isEmpty { line += "  (+\(entry.companions.count) шляхів)" }
                    if !why.isEmpty { line += "  · \(why)" }
                    out.append(line)
                }
                if entries.count > maxEntriesPerRule {
                    let rest = entries.dropFirst(maxEntriesPerRule).reduce(Int64(0)) { $0 + $1.bytes }
                    out.append("  … ще \(entries.count - maxEntriesPerRule) елементів (\(size(rest)))")
                }
            }
        }

        // --- Програми ---
        out.append("")
        out.append("== ВСТАНОВЛЕНІ ПРОГРАМИ (\(input.apps.count)) ==")
        for app in input.apps {
            out.append("  \(short(app.path))  \(app.bundleID)  \(app.version)")
        }

        // --- Карта місця ---
        out.append("")
        out.append("== КАРТА ЗАЙНЯТОГО МІСЦЯ ==")
        out.append("Найбільші елементи в ключових теках (щоб знайти, що ще можна чистити).")
        let unfinished = input.survey.flatMap(\.items).filter(\.incomplete).count
        if unfinished > 0 {
            out.append("⚠︎ Не всі розміри дорахувались (\(unfinished)): позначені «≥». Це завеликі теки або діагностику перервано.")
        }
        for section in input.survey {
            out.append("")
            out.append("### \(section.title) — \(size(section.totalBytes)), елементів: \(section.totalCount)")
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
            if section.restBytes > 0 { out.append("  … решта дрібніших: \(size(section.restBytes))") }
        }
        return out.joined(separator: "\n") + "\n"
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
