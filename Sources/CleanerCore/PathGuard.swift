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
        case .outsideHome(let p): "Поза домашньою папкою: \(p)"
        case .tooShallow(let p): "Занадто високий рівень: \(p)"
        case .protectedPath(let p): "Захищений шлях: \(p)"
        case .insideDenied(let p): "Особисті дані, не чіпаю: \(p)"
        case .escapesHome(let p): "Шлях веде за межі домашньої папки через symlink: \(p)"
        case .invalidName(let p): "Некоректний шлях: \(p)"
        case .notProjectArtifact(let p): "Це не артефакт проєкту: \(p)"
        case .outsideProjectRoots(let p): "Поза папками проєктів: \(p)"
        case .nestedArtifact(let p): "Вкладений артефакт, не чіпаю: \(p)"
        case .markerMissing(let p): "Поруч немає файлу проєкту (package.json, Podfile…): \(p)"
        case .notAllowedSystemPath(let p): "Системний шлях не з дозволеного списку: \(p)"
        case .invalidIdentifier(let id): "Некоректний ідентифікатор: \(id)"
        case .outsideFileRoots(let p): "Поза папками користувача (Downloads, Desktop…): \(p)"
        case .protectedContent(let p): "Прихований, пакет чи службова тека: \(p)"
        case .notRegularFile(let p): "Це не звичайний файл: \(p)"
        case .invalidBackup(let p): "Це не резервна копія iPhone: \(p)"
        case .invalidApplication(let p): "Це не сторонній застосунок з /Applications: \(p)"
        case .foreignLeftover(let p): "Залишок не належить цьому застосунку: \(p)"
        }
    }
}

/// Остання лінія оборони перед видаленням. Навіть якщо правило помилкове, ці перевірки
/// не дадуть зачепити домашню папку, документи, пошту чи ключі.
public struct PathGuard: Sendable {
    public let home: URL

    /// Самі ці шляхи видаляти не можна (їхній вміст — можна, якщо правило так каже).
    private let protectedExact: [String]
    /// Ні ці шляхи, ні нічого всередині них чіпати не можна.
    private let deniedTrees: [String]
    /// Точкові винятки з заборон: повний відносний шлях має збігтися з одним із шаблонів (regex з якорями).
    /// Дозволяють видалити саму теку, але не нічого всередині чи поруч.
    private let allowedExceptions: [String]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL
        protectedExact = [
            "", "Library", "Library/Caches", "Library/Logs", "Library/Application Support",
            "Library/Developer", "Library/Containers", "Library/Group Containers",
            "Library/Preferences", "Library/LaunchAgents", "Library/Fonts",
            ".Trash", ".config", ".local", ".cache",
        ]
        deniedTrees = [
            "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Public",
            "Applications", "Library/Mobile Documents", "Library/CloudStorage",
            "Library/Keychains", "Library/Messages", "Library/Mail", "Library/Safari",
            "Library/Calendars", "Library/Accounts", "Library/Cookies", "Library/Preferences",
            "Library/Application Support/MobileSync", "Library/Application Support/AddressBook",
            "Library/Application Support/CloudDocs", "Library/Photos",
            ".ssh", ".gnupg", ".aws", ".kube",
        ]
        allowedExceptions = [
            #"^Library/Preferences/Adobe Illustrator [0-9]+ Settings$"#,
        ]
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
        let isException = allowedExceptions.contains { relative.range(of: $0, options: .regularExpression) != nil }
        if !isException {
            if protectedExact.contains(relative) { throw GuardError.protectedPath(path) }
            for denied in deniedTrees where relative == denied || relative.hasPrefix(denied + "/") {
                throw GuardError.insideDenied(path)
            }
        }

        // Батьківська папка після розкриття symlink-ів теж має лишатися в домашній.
        let realHome = home.resolvingSymlinksInPath().path
        let realParent = url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().path
        let realPrefix = realHome.hasSuffix("/") ? realHome : realHome + "/"
        guard realParent == realHome || realParent.hasPrefix(realPrefix) else {
            throw GuardError.escapesHome(path)
        }
    }

    public func isAllowed(_ url: URL) -> Bool {
        (try? validate(url)) != nil
    }
}
