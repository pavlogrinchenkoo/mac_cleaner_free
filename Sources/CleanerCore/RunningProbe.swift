import AppKit
import Darwin
import Foundation

/// Знімок запущених застосунків і процесів. Потрібен, щоб не чистити кеш того, що зараз працює.
public struct RunningSnapshot: Sendable {
    public var bundleIDs: Set<String>
    /// Локалізовані назви запущених застосунків (нижній регістр).
    public var appNames: Set<String>
    /// Лише «звичайні» застосунки (з вікнами й Dock), без фонових служб на кшталт `figma_agent`.
    /// Для нечіткого збігу використовуємо тільки їх: фонова служба не означає, що запущена сама програма.
    public var regularAppNames: Set<String>

    public init(bundleIDs: Set<String> = [], appNames: Set<String> = [], regularAppNames: Set<String>? = nil) {
        self.bundleIDs = bundleIDs
        self.appNames = appNames
        self.regularAppNames = regularAppNames ?? appNames
    }

    public static func current() -> RunningSnapshot {
        var ids = Set<String>()
        var names = Set<String>()
        var regular = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { ids.insert(id) }
            if let name = app.localizedName {
                names.insert(name.lowercased())
                if app.activationPolicy == .regular { regular.insert(name.lowercased()) }
            }
        }
        return RunningSnapshot(bundleIDs: ids, appNames: names, regularAppNames: regular)
    }

    /// Чи можна вважати, що тека кешу `name` належить запущеному застосунку.
    /// Помилятись тут безпечніше в бік «так»: зайве блокування лише змусить закрити застосунок.
    public func ownsCache(named name: String) -> Bool {
        if bundleIDs.contains(name) { return true }
        // Кеші бувають і з суфіксами: `com.google.Chrome.helper`, `com.spotify.client.something`.
        if bundleIDs.contains(where: { name.hasPrefix($0 + ".") }) { return true }
        let lowered = name.lowercased()
        if appNames.contains(lowered) { return true }
        // «Google» належить «Google Chrome», «Adobe» — «Adobe Photoshop 2025». Лише для звичайних застосунків:
        // фонова служба (`figma_agent`) не означає, що запущено сам Figma.
        return lowered.count >= 4 && regularAppNames.contains { $0.contains(lowered) }
    }

    /// Чи запущений застосунок з bundle ID за шаблоном (`com.adobe.*`).
    /// Порівняння без урахування регістру: bundle ID бувають `com.adobe.illustrator` і `com.adobe.Photoshop`.
    public func isRunning(bundlePattern pattern: String) -> Bool {
        bundleIDs.contains { Self.matches(bundleID: $0, pattern: pattern) }
    }

    static func matches(bundleID: String, pattern: String) -> Bool {
        fnmatch(pattern, bundleID, FNM_CASEFOLD) == 0
    }
}

public enum RunningProbe {
    /// Причина, чому правило зараз не можна застосовувати, або `nil`.
    public static func blockReason(for rule: CleanupRule, snapshot: RunningSnapshot) -> String? {
        for pattern in rule.blockedByApps where snapshot.isRunning(bundlePattern: pattern) {
            let running = NSWorkspace.shared.runningApplications.first {
                guard let id = $0.bundleIdentifier else { return false }
                return RunningSnapshot.matches(bundleID: id, pattern: pattern)
            }
            if let name = running?.localizedName { return L("Quit %@", name) }
            return L("Quit the app %@", pattern)
        }
        for pattern in rule.blockedByProcesses where processExists(matching: pattern) {
            return L("Process “%@” is running. For Gradle: ./gradlew --stop", pattern)
        }
        return nil
    }

    public static func processExists(matching pattern: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", pattern]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
