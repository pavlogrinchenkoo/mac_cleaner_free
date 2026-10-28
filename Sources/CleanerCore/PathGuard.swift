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

/// The last line of defence before deletion. Even if a rule is wrong, these checks
/// will not let it touch the home folder, documents, mail or keys.
public struct PathGuard: Sendable {
    public let home: URL

    /// These paths themselves must not be deleted (their contents can be, if the rule says so).
    private let protectedExact: Set<String>
    /// Neither these paths nor anything inside them may be touched.
    private let deniedTrees: [String]
    /// Targeted exceptions to the denials: the full relative path must match one of the patterns (anchored regex).
    /// They allow deleting the folder itself, but nothing inside it or next to it.
    private let allowedExceptions: [String]

    /// The macOS file system is case-insensitive by default (`~/documents` = `~/Documents`), so all
    /// comparisons against the deny lists are done in normalized lowercase.
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

    /// Checks a path relative to the home folder against the deny lists (case-insensitive).
    /// Exceptions (`allowedExceptions`) are deliberately case-sensitive: any other casing stays denied.
    private func checkPolicy(relative: String, path: String) throws {
        if allowedExceptions.contains(where: { relative.range(of: $0, options: .regularExpression) != nil }) { return }
        let folded = Self.fold(relative)
        if protectedExact.contains(folded) { throw GuardError.protectedPath(path) }
        for denied in deniedTrees where folded == denied || folded.hasPrefix(denied + "/") {
            throw GuardError.insideDenied(path)
        }
    }

    /// Throws an error if `url` must not be deleted.
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

        // The parent folder, after resolving symlinks, must also stay inside the home folder...
        let realHome = home.resolvingSymlinksInPath().path
        let realParent = url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().path
        let realPrefix = realHome.hasSuffix("/") ? realHome : realHome + "/"
        guard realParent == realHome || realParent.hasPrefix(realPrefix) else {
            throw GuardError.escapesHome(path)
        }
        // ...and must not lead into a protected place: `Library/Caches/x -> ~/Documents/Work` does not allow
        // deleting `x/Cache`. The item itself may be a symlink: the link itself is deleted, so its last
        // component is not resolved.
        let realRelative = (realParent == realHome ? "" : String(realParent.dropFirst(realPrefix.count)) + "/")
            + url.standardizedFileURL.lastPathComponent
        try checkPolicy(relative: realRelative, path: path)
    }

    public func isAllowed(_ url: URL) -> Bool {
        (try? validate(url)) != nil
    }
}
