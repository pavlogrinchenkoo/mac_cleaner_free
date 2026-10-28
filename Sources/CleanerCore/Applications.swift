import Darwin
import Foundation

/// Встановлена програма й усе, що можна про неї дізнатися без запуску.
public struct InstalledApp: Sendable, Equatable {
    public let url: URL
    public let bundleID: String
    public let name: String
    public let version: String?
    public let lastUsed: Date?
    /// `.app` належить root (Mac App Store, Microsoft тощо): видалення потребує пароля.
    public let isRootOwned: Bool
    /// Назви, за якими шукаємо залишки в Application Support/Caches/Logs.
    public let names: [String]
}

/// Деінсталятор: програми з /Applications і ~/Applications разом із залишками в ~/Library.
public enum AppProvider {
    public static let rule = CleanupRule(
        id: "apps.uninstall", group: "uninstall", title: "Встановлені програми",
        detail: "Програма й усі її залишки (налаштування, кеші, дані) переміщуються в Кошик. Системні програми Apple не показую (лише iMovie, GarageBand, Keynote, Pages, Numbers). Те, що встановлено через Mac App Store чи Microsoft, потребує пароля адміна й видаляється назовсім.",
        risk: .careful, granularity: .selfItem, skipRunningAppCaches: true, moveToTrash: true, bulkSelectable: false)

    public static func installedApps(roots: [URL]) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        for root in roots {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names where name.hasSuffix(".app") {
                let url = root.appendingPathComponent(name)
                var st = stat()
                // Символічні посилання (наприклад Safari з системного томa) пропускаємо.
                guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
                guard let info = readInfo(url), let id = info["CFBundleIdentifier"] as? String, !id.isEmpty,
                      !ApplicationGuard.isProtected(bundleID: id), id != ApplicationGuard.ownBundleID else { continue }

                let base = String(name.dropLast(4))
                let display = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? base
                var names = [display, base]
                if let bundleName = info["CFBundleName"] as? String { names.append(bundleName) }
                apps.append(InstalledApp(
                    url: url, bundleID: id, name: display,
                    version: info["CFBundleShortVersionString"] as? String,
                    lastUsed: FileScanner.lastUsedDate(of: url),
                    isRootOwned: st.st_uid != getuid(),
                    names: Array(Set(names.filter { $0.count >= 3 })).sorted()))
            }
        }
        return apps
    }

    /// Залишки програми, які точно її: за bundle ID, а в Application Support/Caches/Logs ще й за точною назвою.
    public static func leftovers(for app: InstalledApp, home: URL) -> [URL] {
        let library = home.appendingPathComponent("Library")
        let id = app.bundleID
        var found: [URL] = []

        func addIfExists(_ relative: String) {
            let url = library.appendingPathComponent(relative)
            var st = stat()
            if lstat(url.path, &st) == 0 { found.append(url) }
        }

        for relative in [
            "Application Support/\(id)", "Caches/\(id)", "Containers/\(id)", "HTTPStorages/\(id)", "WebKit/\(id)",
            "Application Scripts/\(id)", "Saved Application State/\(id).savedState", "Preferences/\(id).plist",
            "Cookies/\(id).binarycookies", "LaunchAgents/\(id).plist", "Logs/\(id)",
        ] { addIfExists(relative) }

        if let byHost = try? FileManager.default.contentsOfDirectory(atPath: library.appendingPathComponent("Preferences/ByHost").path) {
            for name in byHost where name.hasPrefix(id + ".") && name.hasSuffix(".plist") {
                addIfExists("Preferences/ByHost/\(name)")
            }
        }
        if let groups = try? FileManager.default.contentsOfDirectory(atPath: library.appendingPathComponent("Group Containers").path) {
            for name in groups where name == id || name.hasSuffix("." + id) || name == "group." + id {
                addIfExists("Group Containers/\(name)")
            }
        }
        for name in app.names {
            for folder in ["Application Support", "Caches", "Logs"] { addIfExists("\(folder)/\(name)") }
        }

        var seen = Set<String>()
        return found.filter { seen.insert($0.path).inserted }
    }

    public static func discover(home: URL, roots: [URL]? = nil) -> RuleResult {
        let roots = roots ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        let entries = installedApps(roots: roots).map { app -> Entry in
            let leftovers = leftovers(for: app, home: home)
            var details: [String] = []
            // Дві програми з однаковою назвою (Telegram, Telegram 2) розрізняємо за іменем файлу.
            let fileName = app.url.deletingPathExtension().lastPathComponent
            if fileName != app.name { details.append("\(fileName).app") }
            if let version = app.version { details.append("версія \(version)") }
            details.append(leftovers.isEmpty ? "без залишків" : "залишків: \(leftovers.count)")
            if app.isRootOwned { details.append("потрібен пароль") }
            return Entry(
                ruleID: rule.id, url: app.url, name: app.name, subtitle: details.joined(separator: " · "),
                ageLabel: "відкривали", scope: .application, action: .trashPaths, companions: leftovers,
                ownerName: app.bundleID, activityDate: app.lastUsed,
                ownerTokens: [app.bundleID] + app.names, needsAdmin: app.isRootOwned)
        }
        return RuleResult(rule: rule, entries: entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    private static func readInfo(_ app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}


/// Старі версії Adobe: показуємо розмір і пораду, але нічого не видаляємо самі.
/// Правильно прибирати їх через Creative Cloud: він чистить і службові файли та ліцензії.
public enum AdobeVersions {
    public static let rule = CleanupRule(
        id: "design.adobeVersions", group: "design", title: "Старі версії Adobe (видаляй через Creative Cloud)",
        detail: "Встановлено кілька версій однієї програми. Зайві займають по 3–7 ГБ кожна. Видали їх у Creative Cloud (Програми → ⋯ → Видалити), він прибере й службові файли. Тут я їх лише показую.",
        risk: .careful, granularity: .selfItem, bulkSelectable: false)

    private static let advice = "Видаляй через Creative Cloud: Програми → ⋯ → Видалити"

    /// `Adobe Photoshop 2025` → (`Adobe Photoshop`, 2025).
    static func parse(_ folderName: String) -> (product: String, year: Int)? {
        guard folderName.hasPrefix("Adobe "),
              let range = folderName.range(of: #" \d{4}$"#, options: .regularExpression),
              let year = Int(folderName[range].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return (String(folderName[..<range.lowerBound]), year)
    }

    public static func discover(roots: [URL]) -> RuleResult {
        struct Folder { let url: URL; let name: String }
        var folders: [Folder] = []
        for root in roots {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names where name.hasPrefix("Adobe ") && !name.hasSuffix(".app") {
                let url = root.appendingPathComponent(name)
                var st = stat()
                if lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR { folders.append(Folder(url: url, name: name)) }
            }
        }

        var newestYear: [String: Int] = [:]
        for folder in folders {
            if let parsed = parse(folder.name) { newestYear[parsed.product] = max(newestYear[parsed.product] ?? 0, parsed.year) }
        }

        var entries: [Entry] = []
        for folder in folders {
            var subtitle: String?
            if let parsed = parse(folder.name), let newest = newestYear[parsed.product], parsed.year < newest {
                subtitle = "є новіша версія: \(newest)"
            } else if folder.name.hasSuffix("(Beta)") {
                subtitle = "бета-версія"
            }
            guard let subtitle else { continue }
            entries.append(Entry(
                ruleID: rule.id, url: folder.url, name: folder.name, subtitle: subtitle, ageLabel: "змінено",
                lockedReason: advice, scope: .application, action: .trashPaths, informational: true))
        }
        return RuleResult(rule: rule, entries: entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
}


/// Налаштування старих версій Illustrator у `~/Library/Preferences/Adobe Illustrator NN Settings`.
/// Кожна версія лишає по 4–8 ГБ, а коли програму видалено, ці дані нікому не потрібні.
public enum AdobeSettings {
    public static let rule = CleanupRule(
        id: "design.adobeSettings", group: "design", title: "Налаштування старих версій Illustrator",
        detail: "Налаштування версій Illustrator, яких немає на цьому Mac, по 4–8 ГБ кожна. Налаштування встановлених версій лишаються (їх показано заблокованими). Якщо Illustrator такої версії стоїть не в /Applications, не видаляй. Перемістяться в Кошик.",
        risk: .careful, granularity: .selfItem, blockedByApps: ["com.adobe.illustrator*"], moveToTrash: true)

    /// Старші мажорні версії Illustrator, які є на диску (у `/Applications/Adobe Illustrator 2025/…`).
    public static func installedIllustratorMajors(roots: [URL]) -> Set<Int> {
        var majors = Set<Int>()
        func read(_ app: URL) {
            guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                  let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  (info["CFBundleIdentifier"] as? String)?.lowercased() == "com.adobe.illustrator",
                  let version = info["CFBundleShortVersionString"] as? String,
                  let major = Int(version.split(separator: ".").first ?? "")
            else { return }
            majors.insert(major)
        }
        for root in roots {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names where name.hasPrefix("Adobe Illustrator") {
                let url = root.appendingPathComponent(name)
                if name.hasSuffix(".app") { read(url); continue }
                for inner in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] where inner.hasSuffix(".app") {
                    read(url.appendingPathComponent(inner))
                }
            }
        }
        return majors
    }

    static func major(fromFolder name: String) -> Int? {
        guard name.range(of: #"^Adobe Illustrator [0-9]+ Settings$"#, options: .regularExpression) != nil else { return nil }
        return Int(name.dropFirst("Adobe Illustrator ".count).dropLast(" Settings".count))
    }

    public static func discover(home: URL, applicationRoots: [URL]) -> RuleResult {
        let preferences = home.appendingPathComponent("Library/Preferences")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        let installed = installedIllustratorMajors(roots: applicationRoots)

        var entries: [Entry] = []
        for name in names {
            guard let major = major(fromFolder: name) else { continue }
            let url = preferences.appendingPathComponent(name)
            var st = stat()
            guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            let isInstalled = installed.contains(major)
            entries.append(Entry(
                ruleID: rule.id, url: url, name: name,
                subtitle: isInstalled ? "ця версія встановлена" : "версії \(major) немає на цьому Mac",
                ageLabel: "змінено",
                lockedReason: isInstalled ? "Ця версія Illustrator встановлена" : nil,
                scope: .home, action: .trashPaths, informational: isInstalled))
        }
        entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return RuleResult(rule: rule, entries: entries)
    }
}
