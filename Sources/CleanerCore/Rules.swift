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

    /// Custom rules can be added here without recompiling:
    /// `~/Library/Application Support/Cleaner/rules.json` (the same format as the built-in one).
    public static func userRulesURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Cleaner/rules.json")
    }

    /// The resource `<name>.json`: in the built .app the script puts it straight into Contents/Resources,
    /// while under `swift run`/tests it lives in the SwiftPM bundle next to the executable.
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

    /// Built-in rules (in English) with titles and descriptions translated into `language`, if a translation exists.
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

    /// Built-in rules + user rules (if the file exists). A rule with the same `id` overrides the built-in one.
    /// User rules stay as written: they are not translated. They are marked `isCustom`:
    /// they are not selected automatically, and `requiresAdmin` from the file is ignored.
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
    /// `~` and `~/…` → a path in the home folder.
    public static func expandTilde(_ pattern: String, home: URL) -> String {
        if pattern == "~" { return home.path }
        if pattern.hasPrefix("~/") { return home.path + "/" + pattern.dropFirst(2) }
        return pattern
    }

    /// Expands `~`, `*` and `{a,b}` in a path. Returns only paths that exist (symlinks are not resolved).
    public static func expand(_ pattern: String, home: URL) -> [URL] {
        let expanded = expandTilde(pattern, home: home)

        guard expanded.contains(where: { "*?[{".contains($0) }) else {
            return exists(expanded) ? [URL(fileURLWithPath: expanded)] : []
        }

        var matches = glob_t()
        defer { globfree(&matches) }
        // GLOB_BRACE: support for `{Cache,Code Cache,GPUCache}`.
        guard glob(expanded, GLOB_BRACE, nil, &matches) == 0 else { return [] }
        return (0..<Int(matches.gl_pathc)).compactMap { index in
            matches.gl_pathv[index].map { URL(fileURLWithPath: String(cString: $0)) }
        }
    }

    /// `lstat`, not `fileExists`: a broken symlink also "exists" and can be removed.
    private static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// Matches a name against a glob pattern (`com.apple.*`).
    public static func matches(name: String, pattern: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }
}
