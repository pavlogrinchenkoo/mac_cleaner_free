import Foundation

public enum GuardError: Error, LocalizedError, Equatable {
    case outsideHome(String)
    case tooShallow(String)
    case protectedPath(String)
    case insideDenied(String)
    case escapesHome(String)
    case invalidName(String)
    case notProjectArtifact(String)
    case outsideProjectRoots(String)
    case nestedArtifact(String)
    case markerMissing(String)
    case notAllowedSystemPath(String)
    case invalidIdentifier(String)
    case outsideFileRoots(String)
    case protectedContent(String)
    case notRegularFile(String)
    case invalidBackup(String)
    case invalidApplication(String)
    case foreignLeftover(String)

    public var errorDescription: String? {
        switch self {
        case .outsideHome(let p): L("Outside the home folder: %@", p)
        case .tooShallow(let p): L("Path is too shallow: %@", p)
        case .protectedPath(let p): L("Protected path: %@", p)
        case .insideDenied(let p): L("Personal data, leaving it alone: %@", p)
        case .escapesHome(let p): L("Path leaves the home folder through a symlink: %@", p)
        case .invalidName(let p): L("Invalid path: %@", p)
        case .notProjectArtifact(let p): L("Not a project artifact: %@", p)
        case .outsideProjectRoots(let p): L("Outside the project folders: %@", p)
        case .nestedArtifact(let p): L("Nested artifact, leaving it alone: %@", p)
        case .markerMissing(let p): L("No project file next to it (package.json, Podfile…): %@", p)
        case .notAllowedSystemPath(let p): L("System path is not on the allowed list: %@", p)
        case .invalidIdentifier(let id): L("Invalid identifier: %@", id)
        case .outsideFileRoots(let p): L("Outside the user folders (Downloads, Desktop…): %@", p)
        case .protectedContent(let p): L("Hidden item, package or system folder: %@", p)
        case .notRegularFile(let p): L("Not a regular file: %@", p)
        case .invalidBackup(let p): L("Not an iPhone backup: %@", p)
        case .invalidApplication(let p): L("Not a third-party app from /Applications: %@", p)
        case .foreignLeftover(let p): L("The leftover does not belong to this app: %@", p)
        }
    }
}

/// Остання лінія оборони перед видаленням. Навіть якщо правило помилкове, ці перевірки
/// не дадуть зачепити домашню папку, документи, пошту чи ключі.
public struct PathGuard: Sendable {
    public let home: URL

    /// Самі ці шляхи видаляти не можна (їхній вміст — можна, якщо правило так каже).
    private let protectedExact: Set<String>
    /// Ні ці шляхи, ні нічого всередині них чіпати не можна.
    private let deniedTrees: [String]
    /// Точкові винятки з заборон: повний відносний шлях має збігтися з одним із шаблонів (regex з якорями).
    /// Дозволяють видалити саму теку, але не нічого всередині чи поруч.
    private let allowedExceptions: [String]

    /// Файлова система macOS за замовчуванням не розрізняє регістр (`~/documents` = `~/Documents`), тож усі
    /// порівняння з переліками заборон ведемо в нормалізованому нижньому регістрі.
    static func fold(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL
        protectedExact = Set([
            "", "Library", "Library/Caches", "Library/Logs", "Library/Application Support",
            "Library/Developer", "Library/Containers", "Library/Group Containers",
            "Library/Preferences", "Library/LaunchAgents", "Library/Fonts",
            ".Trash", ".config", ".local", ".cache",
        ].map(Self.fold))
        deniedTrees = [
            "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Public",
            "Applications", "Library/Mobile Documents", "Library/CloudStorage",
            "Library/Keychains", "Library/Messages", "Library/Mail", "Library/Safari",
            "Library/Calendars", "Library/Accounts", "Library/Cookies", "Library/Preferences",
            "Library/Application Support/MobileSync", "Library/Application Support/AddressBook",
            "Library/Application Support/CloudDocs", "Library/Photos",
            ".ssh", ".gnupg", ".aws", ".kube",
        ].map(Self.fold)
        allowedExceptions = [
            #"^Library/Preferences/Adobe Illustrator [0-9]+ Settings$"#,
        ]
    }

    /// Перевірка шляху відносно домашньої папки проти переліків заборон (без урахування регістру).
    /// Винятки (`allowedExceptions`) навмисно чутливі до регістру: інший регістр лишається забороненим.
    private func checkPolicy(relative: String, path: String) throws {
        if allowedExceptions.contains(where: { relative.range(of: $0, options: .regularExpression) != nil }) { return }
        let folded = Self.fold(relative)
        if protectedExact.contains(folded) { throw GuardError.protectedPath(path) }
        for denied in deniedTrees where folded == denied || folded.hasPrefix(denied + "/") {
            throw GuardError.insideDenied(path)
        }
    }

    /// Кидає помилку, якщо видаляти `url` не можна.
    public func validate(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        let homePath = home.path
        let prefix = homePath.hasSuffix("/") ? homePath : homePath + "/"

        guard path.hasPrefix(prefix) else { throw GuardError.outsideHome(path) }
        let relative = String(path.dropFirst(prefix.count))
        guard !relative.isEmpty, !relative.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
        else { throw GuardError.invalidName(path) }

        let components = relative.split(separator: "/")
        guard components.count >= 2 else { throw GuardError.tooShallow(path) }
        try checkPolicy(relative: relative, path: path)

        // Батьківська папка після розкриття symlink-ів теж має лишатися в домашній...
        let realHome = home.resolvingSymlinksInPath().path
        let realParent = url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().path
        let realPrefix = realHome.hasSuffix("/") ? realHome : realHome + "/"
        guard realParent == realHome || realParent.hasPrefix(realPrefix) else {
            throw GuardError.escapesHome(path)
        }
        // ...і не вести у захищене місце: `Library/Caches/x -> ~/Documents/Work` не дає видалити `x/Cache`.
        // Сам елемент може бути symlink-ом: видаляється саме посилання, тому його останню частину не розкриваємо.
        let realRelative = (realParent == realHome ? "" : String(realParent.dropFirst(realPrefix.count)) + "/")
            + url.standardizedFileURL.lastPathComponent
        try checkPolicy(relative: realRelative, path: path)
    }

    public func isAllowed(_ url: URL) -> Bool {
        (try? validate(url)) != nil
    }
}
