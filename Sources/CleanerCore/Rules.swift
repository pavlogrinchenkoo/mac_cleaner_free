import Darwin
import Foundation

public enum RuleLoader {
    public enum LoadError: Error, LocalizedError {
        case builtinMissing

        public var errorDescription: String? { L("Could not find the built-in rules.json") }
    }

    /// Translations of the built-in rules: `rules.<language>.json` next to `rules.json`.
    /// Shape: `{"groups": {"<group id>": "<title>"}, "rules": {"<rule id>": {"title": "…", "detail": "…"}}}`.
    struct RuleTranslations: Decodable {
        struct Texts: Decodable {
            var title: String?
            var detail: String?
        }
        var groups: [String: String] = [:]
        var rules: [String: Texts] = [:]
    }

    /// Свої правила можна додати без перекомпіляції сюди:
    /// `~/Library/Application Support/Cleaner/rules.json` (той самий формат, що й вбудований).
    public static func userRulesURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Cleaner/rules.json")
    }

    /// Ресурс `<name>.json`: у зібраному .app скрипт кладе його прямо в Contents/Resources,
    /// а при `swift run`/тестах він лежить у SwiftPM-бандлі поруч із виконуваним файлом.
    static func resourceURL(_ name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "json") { return url }
        return Bundle.module.url(forResource: name, withExtension: "json")
    }

    public static func builtinRulesURL() -> URL? {
        resourceURL("rules")
    }

    public static func decode(_ data: Data) throws -> RuleSet {
        try JSONDecoder().decode(RuleSet.self, from: data)
    }

    /// Вбудовані правила (англійською) з перекладом назв і описів на `language`, якщо переклад є.
    public static func builtin(language: Language = Loc.current) throws -> RuleSet {
        guard let url = builtinRulesURL() else { throw LoadError.builtinMissing }
        var set = try decode(Data(contentsOf: url))
        guard language != .en,
              let translationURL = resourceURL("rules.\(language.rawValue)"),
              let data = try? Data(contentsOf: translationURL),
              let translations = try? JSONDecoder().decode(RuleTranslations.self, from: data)
        else { return set }

        set.groups = set.groups.map { group in
            guard let title = translations.groups[group.id] else { return group }
            return CleanupGroup(id: group.id, title: title, symbol: group.symbol)
        }
        for index in set.rules.indices {
            guard let texts = translations.rules[set.rules[index].id] else { continue }
            if let title = texts.title { set.rules[index].title = title }
            if let detail = texts.detail { set.rules[index].detail = detail }
        }
        return set
    }

    /// Вбудовані правила + правила користувача (якщо файл є). Правило з тим самим `id` перекриває вбудоване.
    /// Правила користувача лишаються такими, як написані: вони не перекладаються. Їх позначено `isCustom`:
    /// вони не вибираються самі, а `requiresAdmin` з файлу ігнорується.
    public static func load(
        home: URL = FileManager.default.homeDirectoryForCurrentUser, language: Language = Loc.current
    ) throws -> RuleSet {
        var set = try builtin(language: language)
        let userURL = userRulesURL(home: home)
        guard let data = try? Data(contentsOf: userURL) else { return set }
        let user = try decode(data)
        for group in user.groups where !set.groups.contains(where: { $0.id == group.id }) {
            set.groups.append(group)
        }
        for var rule in user.rules {
            rule.isCustom = true
            rule.requiresAdmin = false
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
