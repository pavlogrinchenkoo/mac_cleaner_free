import Foundation

/// Знаходить iOS-симулятори й їхні runtimes через `xcrun simctl`.
public enum SimulatorProvider {
    static let xcrun = "/usr/bin/xcrun"

    // MARK: Пристрої

    public static func deviceEntries(
        runner: CommandRunner, ruleID: String, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [Entry] {
        let result = runner.run(xcrun, ["simctl", "list", "devices", "-j"])
        guard result.status == 0 else { return [] }
        return parseDevices(Data(result.output.utf8), ruleID: ruleID, home: home)
    }

    public static func parseDevices(_ json: Data, ruleID: String, home: URL) -> [Entry] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let byRuntime = root["devices"] as? [String: [[String: Any]]]
        else { return [] }

        let iso = ISO8601DateFormatter()
        var entries: [Entry] = []
        for (runtimeKey, devices) in byRuntime {
            for device in devices {
                guard let udid = device["udid"] as? String, let name = device["name"] as? String else { continue }
                let dataPath = device["dataPath"] as? String
                // dataPath вказує на `.../Devices/<UDID>/data`; видаляємо весь пристрій.
                let directory = dataPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
                    ?? home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)")

                let available = device["isAvailable"] as? Bool ?? true
                let state = device["state"] as? String ?? "Shutdown"
                var subtitle = runtimeLabel(runtimeKey)
                if !available { subtitle += " · недоступний (runtime видалено)" }

                let lastBooted = (device["lastBootedAt"] as? String).flatMap { iso.date(from: $0) }
                var preset: DiskUsage?
                if let size = (device["dataPathSize"] as? NSNumber)?.int64Value, size > 0 {
                    preset = DiskUsage(bytes: size, fileCount: 0, lastModified: lastBooted, hadErrors: false)
                }

                entries.append(Entry(
                    ruleID: ruleID, url: directory, name: name, subtitle: subtitle, ageLabel: "запускався",
                    lockedReason: state == "Shutdown" ? nil : "Симулятор запущений, спершу вимкни його",
                    action: .simctlDeleteDevice(udid: udid), presetUsage: preset
                ))
            }
        }
        return entries.sorted { lhs, rhs in
            if lhs.subtitle != rhs.subtitle { return (lhs.subtitle ?? "") < (rhs.subtitle ?? "") }
            return lhs.name < rhs.name
        }
    }

    // MARK: Runtimes

    public static func runtimeEntries(runner: CommandRunner, ruleID: String) -> [Entry] {
        let result = runner.run(xcrun, ["simctl", "runtime", "list", "-j"])
        guard result.status == 0 else { return [] }
        return parseRuntimes(Data(result.output.utf8), ruleID: ruleID)
    }

    public static func parseRuntimes(_ json: Data, ruleID: String) -> [Entry] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: [String: Any]] else { return [] }

        struct Runtime {
            let id: String, identifier: String, version: String, build: String
            let size: Int64, path: String, deletable: Bool, lastUsed: Date?
        }
        let iso = ISO8601DateFormatter()
        let runtimes: [Runtime] = root.compactMap { key, value in
            guard let identifier = value["runtimeIdentifier"] as? String,
                  let version = value["version"] as? String else { return nil }
            return Runtime(
                id: (value["identifier"] as? String) ?? key,
                identifier: identifier, version: version, build: (value["build"] as? String) ?? "",
                size: (value["sizeBytes"] as? NSNumber)?.int64Value ?? 0,
                path: (value["path"] as? String) ?? "",
                deletable: value["deletable"] as? Bool ?? true,
                lastUsed: (value["lastUsedAt"] as? String).flatMap { iso.date(from: $0) }
            )
        }

        // Для кожного runtime шукаємо новішу збірку того ж платформного випуску (17.0 → 17.0.1).
        let newestByIdentifier = Dictionary(grouping: runtimes, by: \.identifier).mapValues { group in
            group.max { VersionedName.isNewer(numbers($1.version), than: numbers($0.version)) }!.version
        }

        return runtimes.map { runtime in
            var subtitle: String?
            if let newest = newestByIdentifier[runtime.identifier], newest != runtime.version {
                subtitle = "Є новіша збірка цього ж runtime: \(newest)"
            }
            let label = "\(runtimeLabel(runtime.identifier, fallbackVersion: runtime.version)) (\(runtime.build))"
            return Entry(
                ruleID: ruleID, url: URL(fileURLWithPath: runtime.path.isEmpty ? "/" : runtime.path),
                id: "simruntime:\(runtime.id)", name: label, subtitle: subtitle, ageLabel: "використовувався",
                lockedReason: runtime.deletable ? nil : "Частина Xcode, видалити не можна",
                action: .simctlDeleteRuntime(id: runtime.id),
                presetUsage: DiskUsage(bytes: runtime.size, fileCount: 0, lastModified: runtime.lastUsed, hadErrors: false)
            )
        }.sorted { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    // MARK: Допоміжне

    private static func numbers(_ version: String) -> [Int] {
        version.split(separator: ".").compactMap { Int($0) }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-17-5` → `iOS 17.5`.
    static func runtimeLabel(_ identifier: String, fallbackVersion: String? = nil) -> String {
        guard let tail = identifier.components(separatedBy: "SimRuntime.").last, tail != identifier else {
            return identifier
        }
        let parts = tail.split(separator: "-")
        guard let platform = parts.first else { return identifier }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? String(platform) : "\(platform) \(fallbackVersion ?? version)"
    }
}
