import AppKit
import Darwin
import Foundation

/// Snapshot of running apps and processes. Needed so we do not clean the cache of something that is running now.
public struct RunningSnapshot: Sendable {
    public var bundleIDs: Set<String>
    /// Localized names of running apps (lowercase).
    public var appNames: Set<String>
    /// Only "regular" apps (with windows and a Dock icon), without background services such as `figma_agent`.
    /// Only these are used for fuzzy matching: a background service does not mean the app itself is running.
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

    /// Whether the cache folder `name` can be considered to belong to a running app.
    /// It is safer to err on the side of "yes" here: an unnecessary block only forces the user to quit the app.
    public func ownsCache(named name: String) -> Bool {
        if bundleIDs.contains(name) { return true }
        // Caches can also have suffixes: `com.google.Chrome.helper`, `com.spotify.client.something`.
        if bundleIDs.contains(where: { name.hasPrefix($0 + ".") }) { return true }
        let lowered = name.lowercased()
        if appNames.contains(lowered) { return true }
        // "Google" belongs to "Google Chrome", "Adobe" to "Adobe Photoshop 2025". Only for regular apps:
        // a background service (`figma_agent`) does not mean Figma itself is running.
        return lowered.count >= 4 && regularAppNames.contains { $0.contains(lowered) }
    }

    /// Whether an app whose bundle ID matches the pattern (`com.adobe.*`) is running.
    /// The comparison is case-insensitive: bundle IDs can be `com.adobe.illustrator` and `com.adobe.Photoshop`.
    public func isRunning(bundlePattern pattern: String) -> Bool {
        bundleIDs.contains { Self.matches(bundleID: $0, pattern: pattern) }
    }

    static func matches(bundleID: String, pattern: String) -> Bool {
        fnmatch(pattern, bundleID, FNM_CASEFOLD) == 0
    }
}

public enum RunningProbe {
    /// The reason the rule cannot be applied right now, or `nil`.
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
