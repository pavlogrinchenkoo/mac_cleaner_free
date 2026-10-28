import Foundation

/// Видалення в системних папках (потребує пароля адміна). Лише короткий список коренів.
public struct SystemPathGuard: Sendable {
    public static let defaultRoots = ["/Library/Caches", "/Library/Logs"]

    public let roots: [String]

    public init(roots: [String] = SystemPathGuard.defaultRoots) {
        self.roots = roots
    }

    public func validate(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        guard let root = roots.first(where: { path.hasPrefix($0 + "/") }) else {
            throw GuardError.notAllowedSystemPath(path)
        }
        let relative = path.dropFirst(root.count + 1)
        guard !relative.isEmpty, !relative.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            throw GuardError.invalidName(path)
        }
        // Батьківська папка після розкриття symlink-ів не має вилазити за корінь.
        let realRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let realParent = url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard realParent == realRoot || realParent.hasPrefix(realRoot + "/") else {
            throw GuardError.escapesHome(path)
        }
    }
}

/// Видалення артефактів проєктів (node_modules, build, Pods…). Це єдине місце, де дозволено
/// чіпати `~/Documents` і подібне, і лише в папках, які користувач сам додав як «папки проєктів».
public struct ArtifactGuard: Sendable {
    public let home: URL
    /// Лише валідні корені.
    public let roots: [URL]

    public init(home: URL, roots: [URL]) {
        let home = home.standardizedFileURL
        self.home = home
        self.roots = roots.map(\.standardizedFileURL).filter { Self.isValidRoot($0, home: home) }
    }

    /// Корінь має бути всередині домашньої папки, але не сама вона, не Library і не службові папки.
    public static func isValidRoot(_ url: URL, home: URL) -> Bool {
        let homePath = home.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(homePath + "/") else { return false }
        let relative = path.dropFirst(homePath.count + 1)
        guard let first = relative.split(separator: "/").first else { return false }
        return !first.hasPrefix(".") && first != "Library" && first != "Applications"
    }

    public func validate(_ url: URL) throws {
        let std = url.standardizedFileURL
        let path = std.path
        guard let kind = ArtifactKind.kind(forDirectoryNamed: std.lastPathComponent) else {
            throw GuardError.notProjectArtifact(path)
        }
        guard let root = roots.first(where: { path.hasPrefix($0.path + "/") }) else {
            throw GuardError.outsideProjectRoots(path)
        }

        let parent = std.deletingLastPathComponent()
        // Між коренем і артефактом не має бути іншого артефакту: вкладені (node_modules/x/node_modules) не чіпаємо.
        let between = parent.path.dropFirst(root.path.count).split(separator: "/")
        if between.contains(where: { ArtifactKind.isArtifactName(String($0)) }) {
            throw GuardError.nestedArtifact(path)
        }

        let realRoot = root.resolvingSymlinksInPath().path
        let realParent = parent.resolvingSymlinksInPath().path
        guard realParent == realRoot || realParent.hasPrefix(realRoot + "/") else {
            throw GuardError.escapesHome(path)
        }

        guard kind.isSatisfied(artifact: std) else { throw GuardError.markerMissing(path) }
    }
}

/// Особисті файли (великі, інсталятори, дублікати). Лише звичайні файли в типових папках користувача,
/// які переміщуються в Кошик. Прихованого, пакетів (.app, .photoslibrary…) і службових тек не торкається.
public struct UserFileGuard: Sendable {
    public static let defaultRootNames = ["Downloads", "Desktop", "Documents", "Movies", "Music", "Pictures"]

    /// Теки-пакети: для Finder це один файл, а всередині живуть бібліотеки й проєкти.
    public static let packageExtensions: Set<String> = [
        "app", "photoslibrary", "fcpbundle", "lrdata", "imovielibrary", "musiclibrary", "tvlibrary",
        "logicx", "band", "sparsebundle", "xcodeproj", "xcworkspace", "playground", "framework",
        "bundle", "rtfd", "pkg", "mpkg", "dvdmedia", "theatre", "aplibrary",
    ]

    public let home: URL
    public let roots: [URL]

    public init(home: URL, roots: [URL]) {
        let home = home.standardizedFileURL
        self.home = home
        self.roots = roots.map(\.standardizedFileURL).filter { ArtifactGuard.isValidRoot($0, home: home) }
    }

    /// Чи заходити всередину теки під час обходу (спільна логіка для сканера і охоронця).
    public static func shouldDescend(into name: String) -> Bool {
        if name.hasPrefix(".") { return false }
        if packageExtensions.contains((name as NSString).pathExtension.lowercased()) { return false }
        if ArtifactKind.isArtifactName(name) || name == "DerivedData" { return false }
        return true
    }

    public func validate(_ url: URL) throws {
        let std = url.standardizedFileURL
        let path = std.path
        guard let root = roots.first(where: { path.hasPrefix($0.path + "/") }) else {
            throw GuardError.outsideFileRoots(path)
        }
        let components = path.dropFirst(root.path.count + 1).split(separator: "/").map(String.init)
        guard let fileName = components.last else { throw GuardError.invalidName(path) }
        if fileName.hasPrefix(".") { throw GuardError.protectedContent(path) }
        for directory in components.dropLast() where !Self.shouldDescend(into: directory) {
            throw GuardError.protectedContent(path)
        }

        let realRoot = root.resolvingSymlinksInPath().path
        let realParent = std.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard realParent == realRoot || realParent.hasPrefix(realRoot + "/") else {
            throw GuardError.escapesHome(path)
        }

        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw GuardError.notRegularFile(path) }
    }
}

/// Резервні копії iPhone/iPad: лише прямі діти `~/Library/Application Support/MobileSync/Backup`.
public struct BackupGuard: Sendable {
    public let backupRoot: URL

    public init(home: URL) {
        backupRoot = home.standardizedFileURL.appendingPathComponent("Library/Application Support/MobileSync/Backup")
    }

    public func validate(_ url: URL) throws {
        let std = url.standardizedFileURL
        let name = std.lastPathComponent
        guard std.deletingLastPathComponent().path == backupRoot.path,
              name.count >= 20, name.allSatisfy({ $0.isHexDigit || $0 == "-" })
        else { throw GuardError.invalidBackup(std.path) }
        var st = stat()
        guard lstat(std.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { throw GuardError.invalidBackup(std.path) }
    }
}

/// Деінсталятор: застосунок із /Applications чи ~/Applications і його залишки в ~/Library.
public struct ApplicationGuard: Sendable {
    public static let ownBundleID = "com.pavlogrinchenko.cleaner"

    /// Необов'язкові програми Apple, які користувач сам ставив з App Store й може прибрати.
    /// Усе інше з `com.apple.*` (Safari, Finder, Системні налаштування…) недоторканне.
    public static let optionalAppleApps: Set<String> = [
        "com.apple.iMovieApp", "com.apple.garageband10", "com.apple.iWork.Keynote",
        "com.apple.iWork.Pages", "com.apple.iWork.Numbers",
    ]

    static func isProtected(bundleID: String) -> Bool {
        bundleID.hasPrefix("com.apple.") && !optionalAppleApps.contains(bundleID)
    }

    /// Куди можуть потрапляти залишки програм (відносно ~/Library). Нічого поза цим списком не чіпаємо.
    public static let leftoverFolders = [
        "Application Support", "Caches", "Preferences", "Preferences/ByHost", "Containers", "Group Containers",
        "Saved Application State", "HTTPStorages", "WebKit", "Logs", "Cookies", "LaunchAgents", "Application Scripts",
    ]
    /// Лише тут дозволено збіг за назвою програми, а не за bundle ID.
    private static let nameMatchFolders: Set<String> = ["Application Support", "Caches", "Logs"]

    public let home: URL
    public let applicationRoots: [URL]

    public init(home: URL, applicationRoots: [URL]? = nil) {
        let home = home.standardizedFileURL
        self.home = home
        self.applicationRoots = (applicationRoots ?? [
            URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications"),
        ]).map(\.standardizedFileURL)
    }

    public static func bundleIdentifier(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleIdentifier"] as? String
    }

    /// Точний збіг: `com.vendor.foo`, `com.vendor.foo.plist`, `ABC123.com.vendor.foo`, `group.com.vendor.foo`.
    /// Просте `contains` тут небезпечне: `com.vendor.foobar` не належить `com.vendor.foo`.
    static func matches(name: String, bundleID: String) -> Bool {
        name == bundleID || name.hasPrefix(bundleID + ".") || name.hasSuffix("." + bundleID) || name == "group." + bundleID
    }

    public func validate(_ entry: Entry) throws {
        let app = entry.url.standardizedFileURL
        let path = app.path
        guard app.pathExtension == "app",
              applicationRoots.contains(where: { $0.path == app.deletingLastPathComponent().path })
        else { throw GuardError.invalidApplication(path) }

        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { throw GuardError.invalidApplication(path) }

        guard let bundleID = Self.bundleIdentifier(of: app), !bundleID.isEmpty,
              !Self.isProtected(bundleID: bundleID), bundleID != Self.ownBundleID,
              entry.ownerTokens.first == bundleID
        else { throw GuardError.invalidApplication(path) }

        let names = entry.ownerTokens.dropFirst().filter { $0.count >= 3 }
        let library = home.appendingPathComponent("Library").path
        for companion in entry.companions {
            let std = companion.standardizedFileURL
            let parent = std.deletingLastPathComponent().path
            let name = std.lastPathComponent
            guard let folder = Self.leftoverFolders.first(where: { library + "/" + $0 == parent }) else {
                throw GuardError.foreignLeftover(std.path)
            }
            let byID = Self.matches(name: name, bundleID: bundleID)
            let byName = Self.nameMatchFolders.contains(folder) && names.contains(name)
            guard byID || byName else { throw GuardError.foreignLeftover(std.path) }
        }
    }
}

/// Усі правила безпеки в одному місці: для кожного елемента вибирає потрібного охоронця.
public struct SafetyPolicy: Sendable {
    public let home: PathGuard
    public let artifacts: ArtifactGuard
    public let system: SystemPathGuard
    public let files: UserFileGuard
    public let backups: BackupGuard
    public let applications: ApplicationGuard

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        projectRoots: [URL] = [],
        fileRoots: [URL] = [],
        systemRoots: [String] = SystemPathGuard.defaultRoots,
        applicationRoots: [URL]? = nil
    ) {
        self.home = PathGuard(home: home)
        self.artifacts = ArtifactGuard(home: home, roots: projectRoots)
        self.system = SystemPathGuard(roots: systemRoots)
        self.files = UserFileGuard(home: home, roots: fileRoots)
        self.backups = BackupGuard(home: home)
        self.applications = ApplicationGuard(home: home, applicationRoots: applicationRoots)
    }

    /// Кидає помилку, якщо з цим елементом не можна нічого робити.
    public func validate(_ entry: Entry) throws {
        switch entry.action {
        case .simctlDeleteDevice(let udid):
            guard UUID(uuidString: udid) != nil else { throw GuardError.invalidIdentifier(udid) }
        case .simctlDeleteRuntime(let id):
            guard UUID(uuidString: id) != nil else { throw GuardError.invalidIdentifier(id) }
        case .removePaths, .trashPaths:
            switch entry.scope {
            case .home: for url in [entry.url] + entry.companions { try home.validate(url) }
            case .project: for url in [entry.url] + entry.companions { try artifacts.validate(url) }
            case .system: for url in [entry.url] + entry.companions { try system.validate(url) }
            case .userFile: for url in [entry.url] + entry.companions { try files.validate(url) }
            case .backup: try backups.validate(entry.url)
            case .application: try applications.validate(entry)
            }
        }
    }
}
