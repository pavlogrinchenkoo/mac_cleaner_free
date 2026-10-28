import Foundation

// LOCALIZATION
//
// English is the source language. Every string a user can see is written in English in the code and passed
// through `L(...)`; `Translations.uk` maps the English text to Ukrainian. An English key that has no
// translation is shown as is, so a missing entry degrades gracefully instead of crashing.
//
//     L("Dry run")                                   // plain text
//     L("Used %ld days ago", age)                    // %ld = Int, %lld = Int64, %@ = String
//     L("%1$@ of %2$@", used, total)                 // positional specifiers when the word order differs
//
// Rules for translation tables (Sources/CleanerCore/Localization/Strings.*.swift):
//  - the key is the exact English string passed to `L` (a plain literal, never built dynamically);
//  - the Ukrainian value keeps the same format specifiers (the tests compare them);
//  - never put user-visible text in `L` that is also used as an identifier or parsed back by the code.

/// Interface languages.
public enum Language: String, CaseIterable, Sendable, Identifiable {
    case en, uk

    public var id: String { rawValue }

    /// Name in its own language, for the language picker.
    public var nativeName: String {
        switch self {
        case .en: "English"
        case .uk: "Українська"
        }
    }

    public var locale: Locale {
        Locale(identifier: self == .en ? "en_US" : "uk_UA")
    }
}

public enum Loc {
    /// Environment variable that forces the language (for `cleanerctl`, tests and self-check): `en` or `uk`.
    public static let environmentKey = "CLEANER_LANGUAGE"

    /// The language of the Mac's preferred-language list: Ukrainian if it comes first among `uk`/`en`,
    /// otherwise English.
    public static func systemLanguage(preferred: [String] = Locale.preferredLanguages) -> Language {
        for tag in preferred {
            let code = tag.lowercased()
            if code.hasPrefix("uk") { return .uk }
            if code.hasPrefix("en") { return .en }
        }
        return .en
    }

    /// `CLEANER_LANGUAGE` if set and valid, otherwise the system language.
    public static func initialLanguage(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preferred: [String] = Locale.preferredLanguages
    ) -> Language {
        if let raw = environment[environmentKey]?.lowercased(), let forced = Language(rawValue: raw) { return forced }
        return systemLanguage(preferred: preferred)
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var language = Loc.initialLanguage()

        var value: Language {
            get { lock.lock(); defer { lock.unlock() }; return language }
            set { lock.lock(); defer { lock.unlock() }; language = newValue }
        }
    }

    private static let box = Box()

    /// The language used by `L(...)`. Safe to read and change from any thread.
    public static var current: Language {
        get { box.value }
        set { box.value = newValue }
    }

    public static func translate(_ key: String, to language: Language = Loc.current) -> String {
        switch language {
        case .en: key
        case .uk: Translations.uk[key] ?? key
        }
    }

    // MARK: - Numbers and sizes

    /// Disk size, e.g. `18.26 GB`; Ukrainian uses a decimal comma and localized units (`18,26`).
    public static func bytes(_ value: Int64, language: Language = Loc.current) -> String {
        let units = language == .uk ? ["Б", "КБ", "МБ", "ГБ", "ТБ"] : ["B", "KB", "MB", "GB", "TB"]
        if value <= 0 { return "0 \(units[1])" }
        let last = units.count - 1
        func digits(_ unit: Int) -> Int { unit <= 1 ? 0 : (unit == 2 ? 1 : 2) }
        var scaled = Double(value)
        var unit = 0
        while true {
            while scaled >= 1000, unit < last {
                scaled /= 1000
                unit += 1
            }
            // Rounding may carry into the next unit (999.6 KB -> 1000 KB -> 1 MB).
            let factor = pow(10, Double(digits(unit)))
            if unit < last, (scaled * factor).rounded() / factor >= 1000 {
                scaled /= 1000
                unit += 1
                continue
            }
            break
        }
        var text = String(format: "%.\(digits(unit))f", scaled)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        if language == .uk { text = text.replacingOccurrences(of: ".", with: ",") }
        return "\(text) \(units[unit])"
    }

    /// "1 item", "5 items"; Ukrainian has three plural forms (one, few, many), e.g. for 1, 2 and 5.
    public static func itemCount(_ n: Int, language: Language = Loc.current) -> String {
        switch language {
        case .en:
            return n == 1 ? "1 item" : "\(n) items"
        case .uk:
            let mod10 = n % 10, mod100 = n % 100
            if mod10 == 1 && mod100 != 11 { return "\(n) елемент" }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "\(n) елементи" }
            return "\(n) елементів"
        }
    }

    /// Picks the right noun form: English uses `one`/`other`; Ukrainian uses `one`/`few`/`many`.
    public static func plural(
        _ n: Int, en: (one: String, other: String), uk: (one: String, few: String, many: String),
        language: Language = Loc.current
    ) -> String {
        switch language {
        case .en:
            return n == 1 ? en.one : en.other
        case .uk:
            let mod10 = n % 10, mod100 = n % 100
            if mod10 == 1 && mod100 != 11 { return uk.one }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return uk.few }
            return uk.many
        }
    }
}

/// Translates a user-visible string (see the notes at the top of this file).
public func L(_ key: String) -> String {
    Loc.translate(key)
}

/// Translates a format string and fills in the arguments (`%ld` Int, `%lld` Int64, `%@` String).
public func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: Loc.translate(key), arguments: arguments)
}
