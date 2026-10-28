import CryptoKit
import CoreServices
import Darwin
import Foundation

/// Налаштування пошуку особистих файлів.
public struct FileScanSettings: Sendable, Equatable {
    /// Де шукати (Downloads, Desktop, Documents, Movies, Music, Pictures).
    public var roots: [URL]
    /// Сюди не заходимо: папки проєктів (там є своя вкладка).
    public var excludedRoots: [URL]
    public var minLargeBytes: Int64
    public var minDuplicateBytes: Int64
    public var minInstallerBytes: Int64
    /// Скільки найбільших файлів показувати максимум.
    public var maxLargeEntries: Int

    public static let defaultMinLargeBytes: Int64 = 100_000_000
    public static let defaultMinDuplicateBytes: Int64 = 5_000_000

    public init(
        roots: [URL], excludedRoots: [URL] = [],
        minLargeBytes: Int64 = FileScanSettings.defaultMinLargeBytes,
        minDuplicateBytes: Int64 = FileScanSettings.defaultMinDuplicateBytes,
        minInstallerBytes: Int64 = 500_000,
        maxLargeEntries: Int = 300
    ) {
        self.roots = roots
        self.excludedRoots = excludedRoots
        self.minLargeBytes = minLargeBytes
        self.minDuplicateBytes = minDuplicateBytes
        self.minInstallerBytes = minInstallerBytes
        self.maxLargeEntries = maxLargeEntries
    }

    /// Типові папки користувача, що існують.
    public static func defaultRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        UserFileGuard.defaultRootNames
            .map { home.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Один файл з інвентаризації.
public struct FileInfo: Sendable, Hashable {
    public let url: URL
    public let allocatedBytes: Int64
    public let logicalBytes: Int64
    public let modified: TimeInterval
    public let created: TimeInterval
    public let device: Int32
    public let inode: UInt64
    public let linkCount: UInt16
}

/// Категорія великого файлу.
public enum FileCategory: String, CaseIterable, Sendable {
    case media, archives, design, other

    public var rule: CleanupRule {
        switch self {
        case .media:
            Self.makeRule(
                "files.large.media", "Великі відео й аудіо",
                "Відео, звук і проєкти монтажу. Перемістяться в Кошик, тож їх можна повернути.")
        case .archives:
            Self.makeRule(
                "files.large.archives", "Великі архіви й образи дисків",
                "Архіви (.zip, .rar…), образи дисків (.dmg, .iso). Часто залишаються після встановлення чи завантаження.")
        case .design:
            Self.makeRule(
                "files.large.design", "Великі дизайн- і фото-файли",
                "Фотошоп, Sketch, Figma-файли, RAW, 3D. Це твоя робота, тож дивись уважно. Перемістяться в Кошик.")
        case .other:
            Self.makeRule(
                "files.large.other", "Інші великі файли",
                "Усе інше більше за заданий розмір. Перемістяться в Кошик.")
        }
    }

    private static func makeRule(_ id: String, _ title: String, _ detail: String) -> CleanupRule {
        CleanupRule(id: id, group: "files", title: title, detail: detail, risk: .careful, granularity: .selfItem, moveToTrash: true, bulkSelectable: false)
    }

    private static let mediaExtensions: Set<String> = [
        "mov", "mp4", "m4v", "mkv", "avi", "webm", "mpg", "mpeg", "wmv", "mts", "m2ts", "mxf", "r3d", "braw",
        "wav", "aif", "aiff", "flac", "mp3", "m4a", "aac", "ogg", "caf",
    ]
    private static let archiveExtensions: Set<String> = [
        "dmg", "iso", "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "pkg", "mpkg", "xip", "img", "sparseimage", "cab",
    ]
    private static let designExtensions: Set<String> = [
        "psd", "psb", "ai", "indd", "indb", "idml", "afdesign", "afphoto", "afpub", "sketch", "fig", "xd",
        "blend", "c4d", "obj", "fbx", "stl", "3ds", "tif", "tiff", "raw", "cr2", "cr3", "nef", "arw", "dng",
        "raf", "orf", "rw2", "exr", "hdr", "psdc", "aep", "prproj",
    ]

    public static func category(forExtension ext: String) -> FileCategory {
        let ext = ext.lowercased()
        if mediaExtensions.contains(ext) { return .media }
        if archiveExtensions.contains(ext) { return .archives }
        if designExtensions.contains(ext) { return .design }
        return .other
    }
}

public enum FileScanner {
    public static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso"]

    public static let installersRule = CleanupRule(
        id: "files.installers", group: "files", title: "Інсталятори в Downloads і на столі",
        detail: "Файли .dmg, .pkg, .iso, які зазвичай уже встановлено й більше не потрібно. Перемістяться в Кошик.",
        risk: .careful, granularity: .selfItem, moveToTrash: true)

    public static let duplicatesRule = CleanupRule(
        id: "files.duplicates", group: "files", title: "Дублікати файлів",
        detail: "Точні копії (збігається весь вміст). У кожній групі один оригінал завжди лишається: його я не пропоную видаляти. На APFS клони файлів можуть не звільнити місця.",
        risk: .careful, granularity: .selfItem, moveToTrash: true)

    public static let allRules: [CleanupRule] =
        [installersRule] + FileCategory.allCases.map(\.rule) + [duplicatesRule]

    // MARK: - Інвентаризація

    /// Один обхід усіх папок: файли від `minBytes`. Пропускає приховане, пакети, git-репозиторії й папки проєктів.
    public static func inventory(settings: FileScanSettings, minBytes: Int64, isCancelled: () -> Bool = { false }) -> [FileInfo] {
        var files: [FileInfo] = []
        let excluded = settings.excludedRoots.map { $0.standardizedFileURL.path }

        for root in settings.roots {
            guard let cRoot = strdup(root.path) else { continue }
            defer { free(cRoot) }
            var argv: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
            guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { continue }
            defer { fts_close(stream) }

            var visited = 0
            while let ent = fts_read(stream) {
                visited += 1
                if visited % 1024 == 0, isCancelled() { return files }
                let info = Int32(ent.pointee.fts_info)
                let path = String(cString: ent.pointee.fts_path)
                let name = (path as NSString).lastPathComponent

                if info == FTS_D {
                    guard ent.pointee.fts_level > 0 else { continue }
                    let dataless = (ent.pointee.fts_statp?.pointee.st_flags ?? 0) & 0x4000_0000 != 0
                    if !UserFileGuard.shouldDescend(into: name) || dataless || DiskSize.isCloudProviderDirectory(path)
                        || excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
                        || isGitRepository(path) {
                        fts_set(stream, ent, FTS_SKIP)
                    }
                } else if info == FTS_F {
                    guard !name.hasPrefix("."), let st = ent.pointee.fts_statp?.pointee,
                          (st.st_mode & S_IFMT) == S_IFREG, (st.st_flags & 0x4000_0000) == 0 // не iCloud-заглушка
                    else { continue }
                    let allocated = Int64(st.st_blocks) * 512
                    guard allocated >= minBytes else { continue }
                    files.append(FileInfo(
                        url: URL(fileURLWithPath: path), allocatedBytes: allocated, logicalBytes: Int64(st.st_size),
                        modified: TimeInterval(st.st_mtimespec.tv_sec), created: TimeInterval(st.st_birthtimespec.tv_sec),
                        device: st.st_dev, inode: UInt64(st.st_ino), linkCount: st.st_nlink))
                }
            }
        }
        return files
    }

    private static func isGitRepository(_ directory: String) -> Bool {
        var st = stat()
        return lstat(directory + "/.git", &st) == 0
    }

    // MARK: - Результати

    /// Повний цикл: інсталятори, великі файли за категоріями, дублікати.
    public static func results(
        settings: FileScanSettings, home: URL,
        status: (String) -> Void = { _ in }, isCancelled: @Sendable () -> Bool = { false }
    ) -> [RuleResult] {
        status("Переглядаю файли…")
        let minimum = min(settings.minLargeBytes, settings.minDuplicateBytes, settings.minInstallerBytes)
        let files = inventory(settings: settings, minBytes: minimum, isCancelled: isCancelled)
        if isCancelled() { return [] }

        status("Шукаю дублікати…")
        let groups = DuplicateFinder.find(files: files, minBytes: settings.minDuplicateBytes, isCancelled: isCancelled)
        if isCancelled() { return [] }

        // Спершу дублікати: їхні зайві копії не показуємо ще й у великих файлах та інсталяторах.
        var duplicateEntries: [Entry] = []
        var duplicateIDs = Set<String>()
        for group in groups {
            let keeper = DuplicateFinder.chooseKeeper(group, home: home)
            for file in group where file.url.path != keeper.url.path {
                duplicateIDs.insert(file.url.path)
                duplicateEntries.append(entry(
                    for: file, rule: duplicatesRule, home: home,
                    subtitle: "Копія: \(abbreviate(keeper.url.path, home: home))",
                    keeper: Keeper(path: keeper.url.path, size: keeper.logicalBytes, modified: keeper.modified)))
            }
        }

        let installerRoots = settings.roots.filter { ["Downloads", "Desktop"].contains($0.lastPathComponent) }.map(\.path)
        var installerEntries: [Entry] = []
        var installerIDs = Set<String>()
        for file in files where file.allocatedBytes >= settings.minInstallerBytes
            && installerExtensions.contains(file.url.pathExtension.lowercased())
            && installerRoots.contains(where: { file.url.path.hasPrefix($0 + "/") })
            && !duplicateIDs.contains(file.url.path) {
            installerIDs.insert(file.url.path)
            installerEntries.append(entry(for: file, rule: installersRule, home: home, subtitle: abbreviate(file.url.deletingLastPathComponent().path, home: home)))
        }

        let large = files
            .filter { $0.allocatedBytes >= settings.minLargeBytes && !duplicateIDs.contains($0.url.path) && !installerIDs.contains($0.url.path) }
            .sorted { $0.allocatedBytes > $1.allocatedBytes }
            .prefix(settings.maxLargeEntries)
        var byCategory: [FileCategory: [Entry]] = [:]
        for file in large {
            let category = FileCategory.category(forExtension: file.url.pathExtension)
            byCategory[category, default: []].append(entry(
                for: file, rule: category.rule, home: home,
                subtitle: abbreviate(file.url.deletingLastPathComponent().path, home: home)))
        }

        var results: [RuleResult] = []
        if !installerEntries.isEmpty { results.append(RuleResult(rule: installersRule, entries: sorted(installerEntries))) }
        for category in FileCategory.allCases {
            if let entries = byCategory[category], !entries.isEmpty {
                results.append(RuleResult(rule: category.rule, entries: sorted(entries)))
            }
        }
        if !duplicateEntries.isEmpty { results.append(RuleResult(rule: duplicatesRule, entries: sorted(duplicateEntries))) }
        return results
    }

    private static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
    }

    private static func entry(for file: FileInfo, rule: CleanupRule, home: URL, subtitle: String, keeper: Keeper? = nil) -> Entry {
        // «Відкривали»: пізніше з двох: останнє відкриття (Spotlight) і зміна файлу.
        // Запит до Spotlight повільний, тож лише для великих файлів.
        let used = (file.allocatedBytes >= 20_000_000 ? lastUsedDate(of: file.url) : nil) ?? .distantPast
        let activity = max(used, Date(timeIntervalSince1970: file.modified))
        var entry = Entry(
            ruleID: rule.id, url: file.url, subtitle: subtitle, ageLabel: "відкривали",
            scope: .userFile, action: .trashPaths,
            presetUsage: DiskUsage(bytes: file.allocatedBytes, fileCount: 1, lastModified: activity, hadErrors: false),
            keeper: keeper)
        entry.measurement = nil
        return entry
    }

    static func abbreviate(_ path: String, home: URL) -> String {
        path.hasPrefix(home.path) ? "~" + path.dropFirst(home.path.count) : path
    }

    /// Дата останнього відкриття з індексу Spotlight (може бути недоступна).
    public static func lastUsedDate(of url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

/// Пошук точних дублікатів: розмір → частковий хеш → повний SHA-256.
public enum DuplicateFinder {
    private static let maxFileBytes: Int64 = 8_000_000_000
    private static let sampleBytes = 65_536

    public static func find(files: [FileInfo], minBytes: Int64, isCancelled: @Sendable () -> Bool = { false }) -> [[FileInfo]] {
        // Hard link-и (той самий inode) — це один файл, не дублікат.
        var seenInodes = Set<String>()
        let candidates = files.filter { file in
            file.logicalBytes >= minBytes && file.logicalBytes <= maxFileBytes
                && seenInodes.insert("\(file.device):\(file.inode)").inserted
        }

        let bySize = Dictionary(grouping: candidates, by: \.logicalBytes).values.filter { $0.count > 1 }
        let sameSize = bySize.flatMap { $0 }
        if sameSize.isEmpty { return [] }

        // Етап 1: початок і кінець файлу.
        let partial = parallelHash(sameSize, isCancelled: isCancelled) { partialHash($0) }
        if isCancelled() { return [] }
        var partialGroups: [String: [FileInfo]] = [:]
        for file in sameSize {
            guard let hash = partial[file.url.path] else { continue }
            partialGroups["\(file.logicalBytes)-\(hash)", default: []].append(file)
        }
        let likely = partialGroups.values.filter { $0.count > 1 }.flatMap { $0 }
        if likely.isEmpty { return [] }

        // Етап 2: весь вміст.
        let full = parallelHash(likely, isCancelled: isCancelled) { fullHash($0) }
        if isCancelled() { return [] }
        var fullGroups: [String: [FileInfo]] = [:]
        for file in likely {
            guard let hash = full[file.url.path] else { continue }
            fullGroups["\(file.logicalBytes)-\(hash)", default: []].append(file)
        }
        return fullGroups.values.filter { $0.count > 1 }
    }

    /// Який файл лишається. Надаємо перевагу тим, що не в Downloads/Desktop, потім давнішим і з коротшим шляхом.
    public static func chooseKeeper(_ group: [FileInfo], home: URL) -> FileInfo {
        func score(_ file: FileInfo) -> Int {
            let path = file.url.path
            let temporary = [home.appendingPathComponent("Downloads").path, home.appendingPathComponent("Desktop").path]
            return temporary.contains { path.hasPrefix($0 + "/") } ? 1 : 0
        }
        return group.min { lhs, rhs in
            if score(lhs) != score(rhs) { return score(lhs) < score(rhs) }
            if lhs.created != rhs.created { return lhs.created < rhs.created }
            if lhs.url.path.count != rhs.url.path.count { return lhs.url.path.count < rhs.url.path.count }
            return lhs.url.path < rhs.url.path
        }!
    }

    // MARK: Хешування

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        func set(_ key: String, _ value: String) { lock.lock(); values[key] = value; lock.unlock() }
        var all: [String: String] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private static func parallelHash(
        _ files: [FileInfo], isCancelled: @Sendable () -> Bool, hash: @Sendable (FileInfo) -> String?
    ) -> [String: String] {
        let results = Results()
        let cancelled = Cancellation()
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            if cancelled.value { return }
            if isCancelled() { cancelled.value = true; return }
            let file = files[index]
            if let value = hash(file) { results.set(file.url.path, value) }
        }
        return results.all
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return flag }
            set { lock.lock(); flag = newValue; lock.unlock() }
        }
    }

    static func partialHash(_ file: FileInfo) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            if file.logicalBytes <= Int64(sampleBytes * 2) {
                guard let data = try handle.readToEnd() else { return nil }
                hasher.update(data: data)
            } else {
                guard let head = try handle.read(upToCount: sampleBytes) else { return nil }
                hasher.update(data: head)
                try handle.seek(toOffset: UInt64(file.logicalBytes) - UInt64(sampleBytes))
                guard let tail = try handle.read(upToCount: sampleBytes) else { return nil }
                hasher.update(data: tail)
            }
        } catch { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fullHash(_ file: FileInfo) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
