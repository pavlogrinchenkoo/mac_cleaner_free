import Foundation

/// Наскільки безпечно видаляти.
public enum Risk: String, Codable, Sendable, CaseIterable {
    /// Кеш, який програма відновить сама. Увімкнено за замовчуванням.
    case safe
    /// Можна видалити, але є ціна (довге перекачування, втрата налаштувань). Вимкнено за замовчуванням.
    case careful
}

/// Група для бокової панелі (Xcode, Android, ...).
public struct CleanupGroup: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String
    /// Назва SF Symbol.
    public let symbol: String

    public init(id: String, title: String, symbol: String) {
        self.id = id
        self.title = title
        self.symbol = symbol
    }
}

/// Декларативне правило очищення: де шукати і що робити з знайденим.
public struct CleanupRule: Codable, Sendable, Identifiable, Hashable {
    public enum Granularity: String, Codable, Sendable {
        /// Кожен збіг шляху — окремий елемент.
        case selfItem = "self"
        /// Кожен вміст збігу (діти) — окремий елемент.
        case children
    }

    public let id: String
    public let group: String
    public let title: String
    /// Що це і що станеться після видалення.
    public let detail: String
    public let risk: Risk
    /// Шляхи з `~` і `*`. Порожньо для правил із `provider`.
    public let paths: [String]
    public let granularity: Granularity
    /// Лише елементи з версією в назві (AndroidStudio2025.3.4); найновішу версію кожної родини не чіпати.
    public let keepNewestVersion: Bool
    /// Не чіпати елементи, у яких щось змінювалось за останні N днів (їх, ймовірно, зараз використовують).
    public let protectRecentDays: Int?
    /// Вибирати за замовчуванням лише елементи, у яких нічого не змінювалось N днів і більше.
    /// Без цього поля безпечні правила вибираються завжди, а обережні ніколи.
    public let autoSelectOlderThanDays: Int?
    /// Glob-шаблони імен, які пропускати.
    public let excludeNames: [String]
    /// Якщо задано, беремо лише імена, що збігаються з одним із шаблонів.
    public let includeNames: [String]
    /// Супутні файли, які видаляються разом з елементом, напр. `{base}.ini` для `Pixel.avd`.
    public let companions: [String]
    /// Bundle ID застосунків; поки хоч один запущений, правило заблоковане.
    public let blockedByApps: [String]
    /// Шаблони для `pgrep -f`; поки є збіг, правило заблоковане.
    public let blockedByProcesses: [String]
    /// Блокувати елемент, якщо його ім'я збігається з bundle ID чи назвою запущеного застосунку.
    public let skipRunningAppCaches: Bool
    /// Правило «решта»: пропускає все, що вже покрито точнішими правилами.
    public let catchAll: Bool
    /// Видалення потребує прав адміна (запит пароля). Дозволено лише для короткого списку системних папок.
    public let requiresAdmin: Bool
    /// Елементи дає код, а не шляхи: `simctl.devices`, `simctl.runtimes`.
    public let provider: String?
    /// Файли переміщуються в Кошик (можна повернути), а не видаляються назовсім.
    public let moveToTrash: Bool
    /// «Власник» елемента — перша тека після незмінної частини шляху (`Application Support/<Власник>/…`).
    /// Потрібен, щоб не чіпати кеш запущеного застосунку.
    public let ownerFromPrefix: Bool
    /// Glob-шаблони власників, яких пропускати (`com.apple.*`). Діє разом з `ownerFromPrefix`.
    public let excludeOwners: [String]
    /// Чи можна одним чекбоксом правила вибрати все. Для особистих файлів (дизайн-файли, програми, бекапи)
    /// ні: там кожен елемент вибирають окремо.
    public let bulkSelectable: Bool

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

/// Результат вимірювання папки/файлу.
public struct DiskUsage: Sendable, Hashable {
    /// Розмір на диску (як у `du`), без подвійного рахунку hard link-ів.
    public var bytes: Int64
    public var fileCount: Int
    /// Найпізніша дата зміни всередині: «коли цим востаннє користувались».
    public var lastModified: Date?
    /// Частину вмісту не вдалося прочитати (немає прав).
    public var hadErrors: Bool
    /// Не встиг дорахувати за відведений час: `bytes` — нижня межа.
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

/// Де лежить елемент і яким правилам безпеки він підпорядковується.
public enum EntryScope: Sendable, Hashable {
    /// Звичайні шляхи в домашній папці.
    case home
    /// Артефакт проєкту (node_modules, build, Pods…) в одній з папок проєктів.
    case project
    /// Системна папка, видалення потребує пароля адміна.
    case system
    /// Особистий файл у Downloads/Desktop/Documents/Movies/Music/Pictures.
    case userFile
    /// Резервна копія iPhone/iPad у `~/Library/Application Support/MobileSync/Backup`.
    case backup
    /// Застосунок із /Applications або ~/Applications разом із залишками.
    case application
}

/// Що саме робимо з елементом.
public enum EntryAction: Sendable, Hashable {
    /// Видалити файли/папки назовсім.
    case removePaths
    /// Перемістити в Кошик (можна повернути).
    case trashPaths
    /// `xcrun simctl delete <udid>`.
    case simctlDeleteDevice(udid: String)
    /// `xcrun simctl runtime delete <id>`.
    case simctlDeleteRuntime(id: String)
}

/// Оригінал, який лишається, коли видаляємо копію (дублікати).
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

/// Один елемент, який можна позначити й видалити.
public struct Entry: Sendable, Identifiable, Hashable {
    /// Унікальний ідентифікатор (зазвичай повний шлях).
    public let id: String
    public let ruleID: String
    public let url: URL
    /// Назва для показу.
    public var name: String
    /// Другий рядок у списку: версія runtime, шлях проєкту тощо.
    public var subtitle: String?
    /// Слово перед датою: «змінено», «активність», «запускався».
    public var ageLabel: String?
    /// `nil`, поки не виміряно.
    public var measurement: DiskUsage?
    /// Постійна причина, чому елемент не можна видаляти (наприклад «остання версія»).
    public var lockedReason: String?
    public var scope: EntryScope
    public var action: EntryAction
    public var companions: [URL]
    /// Розмір відомий наперед (з `simctl`, інвентаризації файлів): міряти не треба.
    public var presetUsage: DiskUsage?
    /// Чий це кеш/застосунок (назва теки чи bundle ID), щоб не чіпати запущене.
    public var ownerName: String?
    /// Дата останнього використання, відома наперед (для програм).
    public var activityDate: Date?
    /// Для дублікатів: оригінал, який має лишитися.
    public var keeper: Keeper?
    /// Для програм: рядки (bundle ID, назва), за якими перевіряємо, що залишки справді їхні.
    public var ownerTokens: [String]
    /// Для програм: `.app` належить root, видалення потребує пароля адміна.
    public var needsAdmin: Bool
    /// Лише показуємо (з розміром і порадою), нічого не робимо. Розмір міряємо, хоч елемент і заблокований.
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

/// Проміжний стан правила після пошуку елементів.
public struct RuleResult: Sendable, Identifiable {
    public let rule: CleanupRule
    public var entries: [Entry]
    /// Правило не вдалося прочитати (наприклад, потрібен Full Disk Access).
    public var accessError: String?

    public var id: String { rule.id }

    public init(rule: CleanupRule, entries: [Entry], accessError: String? = nil) {
        self.rule = rule
        self.entries = entries
        self.accessError = accessError
    }
}

public enum ScanEvent: Sendable {
    /// Знайдено елементи за шляхами (ще без розмірів).
    case discovered([RuleResult])
    /// Додатково знайдено повільнішим шляхом: симулятори, проєкти. Замінює правила з тими ж id.
    case appended([RuleResult])
    /// Виміряно один елемент.
    case measured(id: String, DiskUsage)
    /// Що зараз роблю («Шукаю дублікати…»); `nil`, коли закінчив.
    case status(String?)
    case finished
}
