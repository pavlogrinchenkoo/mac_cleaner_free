import Foundation

/// Резервні копії iPhone/iPad, які Finder зберігає в `~/Library/Application Support/MobileSync/Backup`.
public enum BackupProvider {
    public static var rule: CleanupRule {
        CleanupRule(
            id: "backup.ios", group: "files", title: L("iPhone and iPad backups"),
            detail: L("Copies Finder made from a phone or tablet, often 20–50 GB each. They are moved to the Trash. If this is the only copy of the device, better not to delete it. Full Disk Access is required."),
            risk: .careful, granularity: .children, moveToTrash: true, bulkSelectable: false)
    }

    public static func discover(home: URL) -> RuleResult {
        let root = BackupGuard(home: home).backupRoot
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        } catch {
            // Немає теки: резервних копій немає. Немає доступу: підказуємо про Full Disk Access.
            let denied = FullDiskAccess.isDenied(error)
            return RuleResult(
                rule: rule, entries: [],
                accessError: denied ? L("No access to iPhone backups. Full Disk Access is required.") : nil)
        }

        let guardian = BackupGuard(home: home)
        let entries = names.compactMap { name -> Entry? in
            let url = root.appendingPathComponent(name)
            guard (try? guardian.validate(url)) != nil else { return nil }
            let info = readPlist(url.appendingPathComponent("Info.plist"))
            let manifest = readPlist(url.appendingPathComponent("Manifest.plist"))

            let device = (info?["Device Name"] as? String) ?? L("Unknown device")
            var details: [String] = []
            if let product = info?["Product Name"] as? String {
                details.append(product)
            } else if let type = info?["Product Type"] as? String {
                details.append(type)
            }
            if let version = info?["Product Version"] as? String { details.append(L("version %@", version)) }
            if (manifest?["IsEncrypted"] as? Bool) == true { details.append(L("encrypted")) }

            return Entry(
                ruleID: rule.id, url: url, name: device,
                subtitle: details.joined(separator: " · "), ageLabel: L("backup from"),
                scope: .backup, action: .trashPaths,
                activityDate: info?["Last Backup Date"] as? Date)
        }
        return RuleResult(rule: rule, entries: entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    private static func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
