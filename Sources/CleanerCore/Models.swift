import Foundation

/// How safe it is to delete.
public enum Risk: String, Codable, Sendable, CaseIterable {
    /// A cache the app rebuilds on its own. Enabled by default.
    case safe
    /// Can be deleted, but at a cost (a long re-download, lost settings). Disabled by default.
    case careful
}

/// A group for the sidebar (Xcode, Android, ...).
public struct CleanupGroup: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String
    /// SF Symbol name.
    public let symbol: String

    public init(id: String, title: String, symbol: String) {
        self.id = id
        self.title = title
        self.symbol = symbol
    }
}

/// A declarative cleanup rule: where to look and what to do with what it finds.
public struct CleanupRule: Codable, Sendable, Identifiable, Hashable {
    public enum Granularity: String, Codable, Sendable {
        /// Each path match is a separate item.
        case selfItem = "self"
        /// Each child of a match is a separate item.
        case children
    }

    public let id: String
    public let group: String
    public internal(set) var title: String
    /// What this is and what happens after it is deleted.
    public internal(set) var detail: String
    public let risk: Risk
    /// Paths with `~` and `*`. Empty for rules with a `provider`.
    public let paths: [String]
    public let granularity: Granularity
    /// Only items with a version in the name (AndroidStudio2025.3.4); leave the newest version of each family alone.
    public let keepNewestVersion: Bool
    /// Leave alone items where anything changed in the last N days (they are probably in use right now).
    public let protectRecentDays: Int?
    /// Select by default only items where nothing has changed for N days or more.
    /// Without this field, safe rules are always selected and careful ones never are.
    public let autoSelectOlderThanDays: Int?
    /// Glob patterns for names to skip.
    public let excludeNames: [String]
    /// If set, only names matching one of the patterns are taken.
    public let includeNames: [String]
    /// Companion files deleted together with the item, e.g. `{base}.ini` for `Pixel.avd`.
    public let companions: [String]
    /// App bundle IDs; the rule is blocked while at least one of them is running.
    public let blockedByApps: [String]
    /// Patterns for `pgrep -f`; the rule is blocked while any of them matches.
    public let blockedByProcesses: [String]
    /// Block an item if its name matches the bundle ID or name of a running app.
    public let skipRunningAppCaches: Bool
    /// A "catch-all" rule: skips everything already covered by more specific rules.
    public let catchAll: Bool
    /// Deletion needs administrator rights (password prompt). Allowed only for a short list of system folders.
    public internal(set) var requiresAdmin: Bool
    /// Items come from code rather than from paths: `simctl.devices`, `simctl.runtimes`.
    public let provider: String?
    /// Files are moved to the Trash (recoverable) instead of being deleted permanently.
    public let moveToTrash: Bool
    /// The item's "owner" is the first folder after the fixed part of the path (`Application Support/<Owner>/…`).
    /// Needed so the cache of a running app is left alone.
    public let ownerFromPrefix: Bool
    /// Glob patterns for owners to skip (`com.apple.*`). Works together with `ownerFromPrefix`.
    public let excludeOwners: [String]
    /// Whether a single rule checkbox can select everything. For personal files (design files, apps, backups)
    /// it cannot: each item is selected individually there.
    public let bulkSelectable: Bool
    /// A rule from the user's file (`~/Library/Application Support/Cleaner/rules.json`), not a built-in one.
    /// Not read from JSON: only `RuleLoader` sets it. Such rules are never selected automatically and cannot
    /// ask for the administrator password (the rules file is trusted on its word, and the guards only forbid
    /// what is known).
    public internal(set) var isCustom: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, group, title, detail, risk, paths, granularity
        case keepNewestVersion, protectRecentDays, autoSelectOlderThanDays
        case excludeNames, includeNames, companions
        case blockedByApps, blockedByProcesses, skipRunningAppCaches, catchAll
        case requiresAdmin, provider, moveToTrash, ownerFromPrefix, excludeOwners, bulkSelectable
    }

    public init(
        id: String, group: String, title: String, detail: String, risk: Risk,
        paths: [String] = [], granularity: Granularity = .children,
        keepNewestVersion: Bool = false, protectRecentDays: Int? = nil, autoSelectOlderThanDays: Int? = nil,
        excludeNames: [String] = [], includeNames: [String] = [], companions: [String] = [],
        blockedByApps: [String] = [], blockedByProcesses: [String] = [],
        skipRunningAppCaches: Bool = false, catchAll: Bool = false,
        requiresAdmin: Bool = false, provider: String? = nil,
        moveToTrash: Bool = false, ownerFromPrefix: Bool = false, excludeOwners: [String] = [],
        bulkSelectable: Bool = true
    ) {
        self.id = id
        self.group = group
        self.title = title
        self.detail = detail
        self.risk = risk
        self.paths = paths
        self.granularity = granularity
        self.keepNewestVersion = keepNewestVersion
        self.protectRecentDays = protectRecentDays
        self.autoSelectOlderThanDays = autoSelectOlderThanDays
        self.excludeNames = excludeNames
        self.includeNames = includeNames
        self.companions = companions
        self.blockedByApps = blockedByApps
        self.blockedByProcesses = blockedByProcesses
        self.skipRunningAppCaches = skipRunningAppCaches
        self.catchAll = catchAll
        self.requiresAdmin = requiresAdmin
        self.provider = provider
        self.moveToTrash = moveToTrash
        self.ownerFromPrefix = ownerFromPrefix
        self.excludeOwners = excludeOwners
        self.bulkSelectable = bulkSelectable
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            group: try c.decode(String.self, forKey: .group),
            title: try c.decode(String.self, forKey: .title),
            detail: try c.decode(String.self, forKey: .detail),
            risk: try c.decode(Risk.self, forKey: .risk),
            paths: try c.decodeIfPresent([String].self, forKey: .paths) ?? [],
            granularity: try c.decodeIfPresent(Granularity.self, forKey: .granularity) ?? .children,
            keepNewestVersion: try c.decodeIfPresent(Bool.self, forKey: .keepNewestVersion) ?? false,
            protectRecentDays: try c.decodeIfPresent(Int.self, forKey: .protectRecentDays),
            autoSelectOlderThanDays: try c.decodeIfPresent(Int.self, forKey: .autoSelectOlderThanDays),
            excludeNames: try c.decodeIfPresent([String].self, forKey: .excludeNames) ?? [],
            includeNames: try c.decodeIfPresent([String].self, forKey: .includeNames) ?? [],
            companions: try c.decodeIfPresent([String].self, forKey: .companions) ?? [],
            blockedByApps: try c.decodeIfPresent([String].self, forKey: .blockedByApps) ?? [],
            blockedByProcesses: try c.decodeIfPresent([String].self, forKey: .blockedByProcesses) ?? [],
            skipRunningAppCaches: try c.decodeIfPresent(Bool.self, forKey: .skipRunningAppCaches) ?? false,
            catchAll: try c.decodeIfPresent(Bool.self, forKey: .catchAll) ?? false,
            requiresAdmin: try c.decodeIfPresent(Bool.self, forKey: .requiresAdmin) ?? false,
            provider: try c.decodeIfPresent(String.self, forKey: .provider),
            moveToTrash: try c.decodeIfPresent(Bool.self, forKey: .moveToTrash) ?? false,
            ownerFromPrefix: try c.decodeIfPresent(Bool.self, forKey: .ownerFromPrefix) ?? false,
            excludeOwners: try c.decodeIfPresent([String].self, forKey: .excludeOwners) ?? [],
            bulkSelectable: try c.decodeIfPresent(Bool.self, forKey: .bulkSelectable) ?? true
        )
    }
}

public struct RuleSet: Codable, Sendable {
    public var groups: [CleanupGroup]
    public var rules: [CleanupRule]

    public init(groups: [CleanupGroup], rules: [CleanupRule]) {
        self.groups = groups
        self.rules = rules
    }
}

/// The result of measuring a folder/file.
public struct DiskUsage: Sendable, Hashable {
    /// Size on disk (as in `du`), without double-counting hard links.
    public var bytes: Int64
    public var fileCount: Int
    /// The latest modification date inside: "when this was last used".
    public var lastModified: Date?
    /// Part of the contents could not be read (no permission).
    public var hadErrors: Bool
    /// Did not finish counting within the allotted time: `bytes` is a lower bound.
    public var timedOut: Bool

    public init(bytes: Int64, fileCount: Int, lastModified: Date?, hadErrors: Bool, timedOut: Bool = false) {
        self.bytes = bytes
        self.fileCount = fileCount
        self.lastModified = lastModified
        self.hadErrors = hadErrors
        self.timedOut = timedOut
    }

    public static let zero = DiskUsage(bytes: 0, fileCount: 0, lastModified: nil, hadErrors: false)
}

/// Where an item lives and which safety rules apply to it.
public enum EntryScope: Sendable, Hashable {
    /// Ordinary paths in the home folder.
    case home
    /// A project artifact (node_modules, build, Pods…) in one of the project folders.
    case project
    /// A system folder; deletion needs the administrator password.
    case system
    /// A personal file in Downloads/Desktop/Documents/Movies/Music/Pictures.
    case userFile
    /// An iPhone/iPad backup in `~/Library/Application Support/MobileSync/Backup`.
    case backup
    /// An app from /Applications or ~/Applications together with its leftovers.
    case application
}

/// What exactly is done with the item.
public enum EntryAction: Sendable, Hashable {
    /// Delete files/folders permanently.
    case removePaths
    /// Move to the Trash (recoverable).
    case trashPaths
    /// `xcrun simctl delete <udid>`.
    case simctlDeleteDevice(udid: String)
    /// `xcrun simctl runtime delete <id>`.
    case simctlDeleteRuntime(id: String)
}

/// The original that stays when a copy is deleted (duplicates).
public struct Keeper: Sendable, Hashable {
    public let path: String
    public let size: Int64
    public let modified: TimeInterval

    public init(path: String, size: Int64, modified: TimeInterval) {
        self.path = path
        self.size = size
        self.modified = modified
    }
}

/// A single item that can be marked and deleted.
public struct Entry: Sendable, Identifiable, Hashable {
    /// Unique identifier (usually the full path).
    public let id: String
    public let ruleID: String
    public let url: URL
    /// Display name.
    public var name: String
    /// Second line in the list: runtime version, project path, etc.
    public var subtitle: String?
    /// The word before the date: "modified", "activity", "launched".
    public var ageLabel: String?
    /// `nil` until measured.
    public var measurement: DiskUsage?
    /// A permanent reason why the item cannot be deleted (for example "latest version").
    public var lockedReason: String?
    public var scope: EntryScope
    public var action: EntryAction
    public var companions: [URL]
    /// Size is known in advance (from `simctl`, a file inventory): no need to measure it.
    public var presetUsage: DiskUsage?
    /// Whose cache/app this is (folder name or bundle ID), so that running apps are left alone.
    public var ownerName: String?
    /// Last-used date, known in advance (for apps).
    public var activityDate: Date?
    /// For duplicates: the original that must stay.
    public var keeper: Keeper?
    /// For apps: strings (bundle ID, name) used to check that the leftovers really belong to the app.
    public var ownerTokens: [String]
    /// For apps: the `.app` is owned by root; deletion needs the administrator password.
    public var needsAdmin: Bool
    /// Display only (with size and advice), nothing is done. The size is measured even though the item is blocked.
    public var informational: Bool

    public init(
        ruleID: String, url: URL, id: String? = nil, name: String? = nil, subtitle: String? = nil,
        ageLabel: String? = nil, lockedReason: String? = nil, scope: EntryScope = .home,
        action: EntryAction = .removePaths, companions: [URL] = [], presetUsage: DiskUsage? = nil,
        ownerName: String? = nil, activityDate: Date? = nil, keeper: Keeper? = nil,
        ownerTokens: [String] = [], needsAdmin: Bool = false, informational: Bool = false
    ) {
        self.id = id ?? url.path
        self.ruleID = ruleID
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.subtitle = subtitle
        self.ageLabel = ageLabel
        self.measurement = nil
        self.lockedReason = lockedReason
        self.scope = scope
        self.action = action
        self.companions = companions
        self.presetUsage = presetUsage
        self.ownerName = ownerName
        self.activityDate = activityDate
        self.keeper = keeper
        self.ownerTokens = ownerTokens
        self.needsAdmin = needsAdmin
        self.informational = informational
    }

    public var bytes: Int64 { measurement?.bytes ?? 0 }
}

/// Intermediate state of a rule after its items are found.
public struct RuleResult: Sendable, Identifiable {
    public let rule: CleanupRule
    public var entries: [Entry]
    /// The rule could not be read (for example, Full Disk Access is needed).
    public var accessError: String?

    public var id: String { rule.id }

    public init(rule: CleanupRule, entries: [Entry], accessError: String? = nil) {
        self.rule = rule
        self.entries = entries
        self.accessError = accessError
    }
}

public enum ScanEvent: Sendable {
    /// Items found by path (no sizes yet).
    case discovered([RuleResult])
    /// Additionally found by a slower route: simulators, projects. Replaces rules with the same ids.
    case appended([RuleResult])
    /// One item was measured.
    case measured(id: String, DiskUsage)
    /// What is being done now ("Searching for duplicates…"); `nil` when finished.
    case status(String?)
    case finished
}
