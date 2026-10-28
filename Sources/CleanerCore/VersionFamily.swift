import Foundation

/// Splits names like `AndroidStudio2025.3.4` or `WebStorm2026.1` into a family and a version.
public struct VersionedName: Equatable, Sendable {
    public let family: String
    public let version: [Int]

    /// `nil` if the name does not end with a version like `2025.3` or `2025.3.4`.
    public init?(_ name: String) {
        guard let range = name.range(of: #"\d{4}(\.\d+){1,2}$"#, options: .regularExpression) else { return nil }
        let family = String(name[..<range.lowerBound])
        guard !family.isEmpty else { return nil }
        self.family = family
        self.version = name[range].split(separator: ".").compactMap { Int($0) }
    }

    public static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

public enum VersionFamily {
    /// For each family, returns the name of the newest version.
    public static func newestPerFamily(names: [String]) -> [String: String] {
        var best: [String: (name: String, version: [Int])] = [:]
        for name in names {
            guard let parsed = VersionedName(name) else { continue }
            if let current = best[parsed.family], !VersionedName.isNewer(parsed.version, than: current.version) {
                continue
            }
            best[parsed.family] = (name, parsed.version)
        }
        return best.mapValues(\.name)
    }
}
