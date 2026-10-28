import Darwin
import Foundation

public enum RuleLoader {
    public enum LoadError: Error, LocalizedError {
        case builtinMissing

        public var errorDescription: String? { "Не знайшов вбудований rules.json" }
    }

    /// Свої правила можна додати без перекомпіляції сюди:
    /// `~/Library/Application Support/Cleaner/rules.json` (той самий формат, що й вбудований).
    public static func userRulesURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Cleaner/rules.json")
    }

    public static func builtinRulesURL() -> URL? {
        // У зібраному .app скрипт кладе rules.json прямо в Contents/Resources.
        if let url = Bundle.main.url(forResource: "rules", withExtension: "json") { return url }
        // При `swift run`/тестах ресурс лежить у SwiftPM-бандлі поруч із виконуваним файлом.
        return Bundle.module.url(forResource: "rules", withExtension: "json")
    }

    public static func decode(_ data: Data) throws -> RuleSet {
        try JSONDecoder().decode(RuleSet.self, from: data)
    }

    public static func builtin() throws -> RuleSet {
        guard let url = builtinRulesURL() else { throw LoadError.builtinMissing }
        return try decode(Data(contentsOf: url))
    }

    /// Вбудовані правила + правила користувача (якщо файл є). Правило з тим самим `id` перекриває вбудоване.
    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> RuleSet {
        var set = try builtin()
        let userURL = userRulesURL(home: home)
        guard let data = try? Data(contentsOf: userURL) else { return set }
        let user = try decode(data)
        for group in user.groups where !set.groups.contains(where: { $0.id == group.id }) {
            set.groups.append(group)
        }
        for rule in user.rules {
            if let index = set.rules.firstIndex(where: { $0.id == rule.id }) {
                set.rules[index] = rule
            } else {
                set.rules.append(rule)
            }
        }
        return set
    }
}

public enum PathExpander {
    /// `~` і `~/…` → шлях у домашній папці.
    public static func expandTilde(_ pattern: String, home: URL) -> String {
        if pattern == "~" { return home.path }
        if pattern.hasPrefix("~/") { return home.path + "/" + pattern.dropFirst(2) }
        return pattern
    }

    /// Розкриває `~`, `*` і `{a,b}` у шляху. Повертає лише ті шляхи, що існують (symlink-и не розкриваються).
    public static func expand(_ pattern: String, home: URL) -> [URL] {
        let expanded = expandTilde(pattern, home: home)

        guard expanded.contains(where: { "*?[{".contains($0) }) else {
            return exists(expanded) ? [URL(fileURLWithPath: expanded)] : []
        }

        var matches = glob_t()
        defer { globfree(&matches) }
        // GLOB_BRACE: підтримка `{Cache,Code Cache,GPUCache}`.
        guard glob(expanded, GLOB_BRACE, nil, &matches) == 0 else { return [] }
        return (0..<Int(matches.gl_pathc)).compactMap { index in
            matches.gl_pathv[index].map { URL(fileURLWithPath: String(cString: $0)) }
        }
    }

    /// `lstat`, а не `fileExists`: битий symlink теж «існує» і його можна прибрати.
    private static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// Збіг імені з glob-шаблоном (`com.apple.*`).
    public static func matches(name: String, pattern: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }
}
