import Foundation

/// Розбір назв на кшталт `AndroidStudio2025.3.4` або `WebStorm2026.1` на родину й версію.
public struct VersionedName: Equatable, Sendable {
    public let family: String
    public let version: [Int]

    /// `nil`, якщо в кінці назви немає версії виду `2025.3` чи `2025.3.4`.
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
    /// Для кожної родини повертає назву найновішої версії.
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
