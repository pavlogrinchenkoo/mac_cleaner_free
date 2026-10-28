import XCTest
@testable import CleanerCore

/// Не наслідує CleanerTestCase: сам керує мовою.
final class LocalizationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Loc.current = .en
    }

    override func tearDown() {
        Loc.current = .uk
        super.tearDown()
    }

    // MARK: - Мова

    func testSystemLanguageFollowsTheFirstSupportedPreferredLanguage() {
        XCTAssertEqual(Loc.systemLanguage(preferred: ["uk-UA", "en-US"]), .uk)
        XCTAssertEqual(Loc.systemLanguage(preferred: ["en-US", "uk-UA"]), .en)
        XCTAssertEqual(Loc.systemLanguage(preferred: ["ru-UA", "uk-UA"]), .uk, "непідтримані мови пропускаємо")
        XCTAssertEqual(Loc.systemLanguage(preferred: ["de-DE", "fr-FR"]), .en, "за замовчуванням англійська")
        XCTAssertEqual(Loc.systemLanguage(preferred: []), .en)
    }

    func testEnvironmentOverridesTheSystemLanguage() {
        XCTAssertEqual(Loc.initialLanguage(environment: ["CLEANER_LANGUAGE": "uk"], preferred: ["en-US"]), .uk)
        XCTAssertEqual(Loc.initialLanguage(environment: ["CLEANER_LANGUAGE": "EN"], preferred: ["uk-UA"]), .en)
        XCTAssertEqual(Loc.initialLanguage(environment: ["CLEANER_LANGUAGE": "xx"], preferred: ["uk-UA"]), .uk, "невідому ігноруємо")
        XCTAssertEqual(Loc.initialLanguage(environment: [:], preferred: ["uk-UA"]), .uk)
    }

    func testUnknownKeysFallBackToEnglishAndStillFormat() {
        for language in Language.allCases {
            Loc.current = language
            XCTAssertEqual(L("no such key in any table"), "no such key in any table")
            XCTAssertEqual(L("no such key %@ / %ld", "x", 7), "no such key x / 7")
        }
    }

    // MARK: - Розміри й множина

    func testBytesInEnglish() {
        XCTAssertEqual(Loc.bytes(0, language: .en), "0 KB")
        XCTAssertEqual(Loc.bytes(-5, language: .en), "0 KB")
        XCTAssertEqual(Loc.bytes(999, language: .en), "999 B")
        XCTAssertEqual(Loc.bytes(1_000, language: .en), "1 KB")
        XCTAssertEqual(Loc.bytes(1_500_000, language: .en), "1.5 MB")
        XCTAssertEqual(Loc.bytes(500_000_000, language: .en), "500 MB")
        XCTAssertEqual(Loc.bytes(18_260_000_000, language: .en), "18.26 GB")
        XCTAssertEqual(Loc.bytes(20_000_000_000, language: .en), "20 GB")
        XCTAssertEqual(Loc.bytes(3_400_000_000_000, language: .en), "3.4 TB")
    }

    func testBytesInUkrainianUsesLocalUnitsAndDecimalComma() {
        XCTAssertEqual(Loc.bytes(0, language: .uk), "0 КБ")
        XCTAssertEqual(Loc.bytes(999, language: .uk), "999 Б")
        XCTAssertEqual(Loc.bytes(1_500_000, language: .uk), "1,5 МБ")
        XCTAssertEqual(Loc.bytes(18_260_000_000, language: .uk), "18,26 ГБ")
        XCTAssertEqual(Loc.bytes(20_000_000_000, language: .uk), "20 ГБ")
    }

    func testBytesRoundingCarriesIntoTheNextUnit() {
        XCTAssertEqual(Loc.bytes(999_999, language: .en), "1 MB", "999,999 B не повинно стати «1000 KB»")
        XCTAssertEqual(Loc.bytes(999_950_000, language: .en), "1 GB")
    }

    func testItemCountAndPlurals() {
        XCTAssertEqual(Loc.itemCount(1, language: .en), "1 item")
        XCTAssertEqual(Loc.itemCount(0, language: .en), "0 items")
        XCTAssertEqual(Loc.itemCount(2, language: .en), "2 items")
        let expected: [Int: String] = [
            0: "0 елементів", 1: "1 елемент", 2: "2 елементи", 4: "4 елементи", 5: "5 елементів", 11: "11 елементів",
            12: "12 елементів", 21: "21 елемент", 22: "22 елементи", 25: "25 елементів", 111: "111 елементів",
        ]
        for (n, text) in expected {
            XCTAssertEqual(Loc.itemCount(n, language: .uk), text)
        }
        XCTAssertEqual(Loc.plural(1, en: ("day", "days"), uk: ("день", "дні", "днів"), language: .en), "day")
        XCTAssertEqual(Loc.plural(3, en: ("day", "days"), uk: ("день", "дні", "днів"), language: .uk), "дні")
    }

    // MARK: - Таблиці перекладів

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func sourceFiles() -> [URL] {
        let sources = repoRoot.appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    private func relative(_ url: URL) -> String {
        String(url.path.dropFirst(repoRoot.path.count + 1))
    }

    private func unescape(_ literal: String) -> String {
        var result = "", iterator = literal.makeIterator()
        while let ch = iterator.next() {
            guard ch == "\\", let next = iterator.next() else { result.append(ch); continue }
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            default: result.append(next)
            }
        }
        return result
    }

    /// Усі ключі, що передаються в `L("…")` у коді: `(файл, ключ)`.
    private func usedKeys() throws -> [(file: String, key: String)] {
        let single = try NSRegularExpression(pattern: #"\bL\(\s*"((?:[^"\\\n]|\\.)*)""#)
        let multi = try NSRegularExpression(pattern: #"\bL\(\s*\"\"\"\n((?:.|\n)*?)\n([ \t]*)\"\"\""#)
        var found: [(String, String)] = []
        for file in sourceFiles() where !relative(file).contains("Localization") {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in single.matches(in: text, range: range) {
                guard match.range(at: 1).location != NSNotFound, let r = Range(match.range(at: 1), in: text) else { continue }
                // `L("""` починається з трьох лапок: регулярний вираз single не повинен його зачепити.
                if text[r].isEmpty, text[r.upperBound...].hasPrefix("\"\"") { continue }
                found.append((relative(file), unescape(String(text[r]))))
            }
            for match in multi.matches(in: text, range: range) {
                guard let body = Range(match.range(at: 1), in: text), let indent = Range(match.range(at: 2), in: text) else { continue }
                let strip = text[indent].count
                let lines = text[body].split(separator: "\n", omittingEmptySubsequences: false).map { String($0.dropFirst(strip)) }
                found.append((relative(file), lines.joined(separator: "\n")))
            }
        }
        return found
    }

    func testEveryKeyUsedInCodeHasAUkrainianTranslation() throws {
        let keys = try usedKeys()
        XCTAssertGreaterThan(keys.count, 100, "регулярний вираз знайшов підозріло мало викликів L(…)")
        var missing: [String] = []
        for (file, key) in keys where Translations.uk[key] == nil {
            missing.append("\(file): \(key)")
        }
        XCTAssertTrue(missing.isEmpty, "Немає українського перекладу:\n" + missing.joined(separator: "\n"))
    }

    func testKeysAreStaticLiterals() throws {
        // `L("… \(x) …")` не можна перекласти: ключ має бути сталим рядком із %@/%ld.
        let interpolated = try usedKeys().filter { $0.key.contains("\\(") }
        XCTAssertTrue(interpolated.isEmpty, interpolated.map { "\($0.file): \($0.key)" }.joined(separator: "\n"))
    }

    private func specifiers(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(?:ll|l)?[@dixXfsu]|%%"#)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }.sorted()
    }

    func testTranslationsKeepTheSameFormatSpecifiers() {
        var broken: [String] = []
        for (table, strings) in Translations.tables {
            for (key, value) in strings where specifiers(key) != specifiers(value) {
                broken.append("[\(table)] \(key)  →  \(value)")
            }
        }
        XCTAssertTrue(broken.isEmpty, "Різні специфікатори формату:\n" + broken.joined(separator: "\n"))
    }

    func testTablesDoNotDisagreeAboutTheSameKey() {
        var seen: [String: (table: String, value: String)] = [:]
        var conflicts: [String] = []
        for (table, strings) in Translations.tables {
            for (key, value) in strings {
                if let other = seen[key], other.value != value {
                    conflicts.append("\(key): [\(other.table)] «\(other.value)» ≠ [\(table)] «\(value)»")
                }
                seen[key] = (table, value)
            }
        }
        XCTAssertTrue(conflicts.isEmpty, conflicts.joined(separator: "\n"))
    }

    func testNoUkrainianTextLeaksIntoCodeOutsideTheTables() throws {
        let cyrillic = try NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*[А-Яа-яІіЇїЄєҐґ](?:[^"\\\n]|\\.)*""#)
        var leaks: [String] = []
        for file in sourceFiles() {
            let name = relative(file)
            if name.contains("Localization") { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(rawLine)
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                // Ukrainian noun forms inside `Loc.plural(…, uk: (…))` are the intended place for them.
                if line.contains("Loc.plural(") { continue }
                // Прибираємо коментар у кінці рядка (грубо, але вистачає: `//` усередині рядка тут не трапляється).
                let code = line.range(of: " //").map { String(line[..<$0.lowerBound]) } ?? line
                let range = NSRange(code.startIndex..., in: code)
                if cyrillic.firstMatch(in: code, range: range) != nil {
                    leaks.append("\(name):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(leaks.isEmpty, "Українські рядки в коді поза таблицями:\n" + leaks.joined(separator: "\n"))
    }

    // MARK: - Англійський інтерфейс наскрізно

    private func hasCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    func testBuiltInRulesAreEnglishByDefaultAndUkrainianOnRequest() throws {
        let english = try RuleLoader.builtin(language: .en)
        let ukrainian = try RuleLoader.builtin(language: .uk)
        XCTAssertEqual(english.rules.map(\.id), ukrainian.rules.map(\.id))
        XCTAssertFalse(english.groups.contains { hasCyrillic($0.title) })
        XCTAssertFalse(english.rules.contains { hasCyrillic($0.title) || hasCyrillic($0.detail) })
        // Деякі назви однакові в обох мовах («Xcode DerivedData»), тож перевіряємо, що переклад застосовано
        // до переважної більшості, а кожен опис українською справді українською.
        let translatedGroups = zip(english.groups, ukrainian.groups).filter { $0.title != $1.title }.count
        let translatedRules = zip(english.rules, ukrainian.rules).filter { $0.title != $1.title }.count
        XCTAssertGreaterThanOrEqual(translatedGroups, english.groups.count - 2)
        XCTAssertGreaterThanOrEqual(translatedRules, english.rules.count - 5)
        XCTAssertTrue(ukrainian.rules.allSatisfy { hasCyrillic($0.detail) }, "усі описи правил перекладені")
    }

    func testFullScanAndReportContainNoUkrainianInEnglishMode() async throws {
        Loc.current = .en
        let home = try FakeHome()
        try home.makeFile("Downloads/Setup.dmg", bytes: 200_000)
        try home.makeFile("Downloads/video.mov", bytes: 400_000)
        try home.makeFile("Documents/work.psd", bytes: 500_000)
        let content = Data(repeating: 7, count: 300_000)
        for path in ["Downloads/dup1.bin", "Documents/dup2.bin"] {
            try FileManager.default.createDirectory(at: home.path(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: home.path(path))
        }
        try makeApp(home, at: "Apps/Foo.app", bundleID: "com.vendor.foo", name: "Foo")
        try home.makeFile("Library/Application Support/MobileSync/Backup/00008110-001A2B3C4D5E6F78/blob.bin", bytes: 50_000)
        try home.makeFile("Library/Caches/SomeApp/data.bin", bytes: 40_000)

        let settings = FileScanSettings(
            roots: ["Downloads", "Documents"].map { home.path($0) }, minLargeBytes: 150_000, minDuplicateBytes: 100_000, minInstallerBytes: 50_000)
        let cacheRule = try makeRule(id: "cache", paths: ["~/Library/Caches"])
        let scanner = DiskScanner(ruleSet: makeRuleSet([cacheRule]), home: home.url, fileSettings: settings, applicationRoots: [home.path("Apps")])

        var results: [String: RuleResult] = [:]
        var measured: [String: DiskUsage] = [:]
        var statuses: [String] = []
        for await event in scanner.scan() {
            switch event {
            case .discovered(let found): results = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
            case .appended(let found): for result in found { results[result.id] = result }
            case .measured(let id, let usage): measured[id] = usage
            case .status(let text): if let text { statuses.append(text) }
            default: break
            }
        }

        var texts = statuses
        var entriesWithUsage: [Entry] = []
        for result in results.values {
            texts += [result.rule.title, result.rule.detail] + [result.accessError].compactMap { $0 }
            for var entry in result.entries {
                entry.measurement = measured[entry.id]
                texts += [entry.name, entry.subtitle, entry.ageLabel, entry.lockedReason].compactMap { $0 }
                texts.append(DiskScanner.defaultDecision(entry, rule: result.rule).reason)
                entriesWithUsage.append(entry)
            }
        }
        XCTAssertGreaterThan(entriesWithUsage.count, 5)
        XCTAssertFalse(texts.isEmpty)
        for text in texts {
            XCTAssertFalse(hasCyrillic(text), "українське в англійському режимі: \(text)")
        }

        let report = DiagnosticReport.render(DiagnosticInput(
            appVersion: "1", dryRun: true, macOSVersion: "26", architecture: "arm64", fullDiskAccess: false,
            disk: DiskInfo(totalBytes: 500_000_000_000, freeBytes: 20_000_000_000), projectRoots: [], fileSettings: settings,
            groups: [CleanupGroup(id: "g", title: "Group", symbol: "gear")], results: Array(results.values),
            selectedIDs: Set(entriesWithUsage.prefix(2).map(\.id)), manualIDs: [], ruleBlocks: [:],
            blockReason: { entry, _ in entry.lockedReason }, apps: [], survey: [], home: home.url))
        XCTAssertFalse(report.isEmpty)
        let leaked = report.split(separator: "\n").filter { hasCyrillic(String($0)) }
        XCTAssertTrue(leaked.isEmpty, "українське в англійському звіті:\n" + leaked.joined(separator: "\n"))
    }

    func testTheSameScanReadsInUkrainianWhenSwitched() throws {
        let english = L("Dry run")
        Loc.current = .uk
        let ukrainian = L("Dry run")
        // Якщо ключа немає в таблицях, обидва збігаються: це теж помилка, бо «Dry run» є в інтерфейсі.
        XCTAssertEqual(english, "Dry run")
        XCTAssertEqual(ukrainian, "Пробний запуск")
    }
}
