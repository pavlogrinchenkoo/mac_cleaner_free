import XCTest
@testable import CleanerCore

final class RulesTests: CleanerTestCase {
    func testBuiltinRulesLoad() throws {
        let set = try RuleLoader.builtin()
        XCTAssertFalse(set.rules.isEmpty)
        XCTAssertEqual(Set(set.rules.map(\.id)).count, set.rules.count, "id правил мають бути унікальні")
    }

    func testEveryRuleReferencesExistingGroup() throws {
        let set = try RuleLoader.builtin()
        let groups = Set(set.groups.map(\.id))
        for rule in set.rules {
            XCTAssertTrue(groups.contains(rule.group), "\(rule.id): невідома група \(rule.group)")
        }
    }

    /// The most important test: no path in the built-in rules may point to a forbidden location.
    func testEveryBuiltinRulePathPassesTheSafetyGuard() throws {
        let home = try FakeHome()
        let policy = SafetyPolicy(home: home.url)
        for rule in try RuleLoader.builtin().rules where rule.provider == nil {
            XCTAssertFalse(rule.paths.isEmpty, "\(rule.id): правило без шляхів і без provider")
            for pattern in rule.paths {
                let concrete: String
                if rule.requiresAdmin {
                    XCTAssertTrue(pattern.hasPrefix("/Library/"), "\(rule.id): адмін-правило поза /Library (\(pattern))")
                    concrete = pattern.replacingOccurrences(of: "*", with: "x")
                } else {
                    XCTAssertTrue(pattern.hasPrefix("~/"), "\(rule.id): шлях має починатися з ~/ (\(pattern))")
                    concrete = home.url.path + "/" + pattern.dropFirst(2).replacingOccurrences(of: "*", with: "x")
                }
                let probe = rule.granularity == .children ? concrete + "/x" : concrete
                let url = URL(fileURLWithPath: probe)
                if rule.requiresAdmin {
                    XCTAssertNoThrow(try policy.system.validate(url), "\(rule.id): \(pattern)")
                } else {
                    XCTAssertNoThrow(try policy.home.validate(url), "\(rule.id): \(pattern)")
                }
            }
        }
    }

    func testAdminRulesAreOnlyInAllowlistedSystemRoots() throws {
        for rule in try RuleLoader.builtin().rules where rule.requiresAdmin {
            XCTAssertEqual(rule.risk, .safe, "\(rule.id): адмін-правило має бути лише «безпечним»")
            for pattern in rule.paths {
                XCTAssertTrue(
                    SystemPathGuard.defaultRoots.contains(pattern), "\(rule.id): \(pattern) не в дозволеному списку"
                )
            }
        }
    }

    func testProviderRulesUseKnownProviders() throws {
        for rule in try RuleLoader.builtin().rules {
            if let provider = rule.provider {
                XCTAssertTrue(["simctl.devices", "simctl.runtimes"].contains(provider), "\(rule.id): \(provider)")
                XCTAssertEqual(rule.risk, .careful, "\(rule.id): симулятори мають бути «обережно»")
            }
        }
    }

    func testProjectsGroupExists() throws {
        let set = try RuleLoader.builtin()
        XCTAssertTrue(set.groups.contains { $0.id == "projects" })
        for kind in ArtifactKind.all { XCTAssertEqual(kind.rule.group, "projects") }
    }

    /// A "safe" rule in Application Support may only point to cache folders, never to settings or data.
    func testSafeRulesInApplicationSupportOnlyTargetCacheFolders() throws {
        let cacheMarkers = ["Cache", "Peak Files"]
        for rule in try RuleLoader.builtin().rules where rule.risk == .safe {
            for pattern in rule.paths where pattern.contains("Application Support") {
                let last = pattern.split(separator: "/").last.map(String.init) ?? ""
                XCTAssertTrue(
                    cacheMarkers.contains { last.contains($0) },
                    "\(rule.id): safe-правило в Application Support вказує не на кеш (\(pattern))")
            }
        }
    }

    func testUserRulesOverrideAndExtend() throws {
        let home = try FakeHome()
        let builtin = try RuleLoader.builtin()
        let first = try XCTUnwrap(builtin.rules.first)
        let custom = """
        {"groups":[{"id":"mine","title":"Мої","symbol":"star"}],
         "rules":[
           {"id":"\(first.id)","group":"\(first.group)","title":"Перекрито","detail":"d","risk":"careful","paths":["~/x/y"]},
           {"id":"mine.one","group":"mine","title":"Нове","detail":"d","risk":"safe","paths":["~/a/b"]}
         ]}
        """
        try FileManager.default.createDirectory(at: RuleLoader.userRulesURL(home: home.url).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(custom.utf8).write(to: RuleLoader.userRulesURL(home: home.url))

        let merged = try RuleLoader.load(home: home.url)
        XCTAssertEqual(merged.rules.count, builtin.rules.count + 1)
        XCTAssertEqual(merged.rules.first { $0.id == first.id }?.title, "Перекрито")
        XCTAssertNotNil(merged.rules.first { $0.id == "mine.one" })
        XCTAssertTrue(merged.groups.contains { $0.id == "mine" })
    }

    // MARK: - Rule localization

    private func ukrainianTranslations() throws -> RuleLoader.RuleTranslations {
        let url = try XCTUnwrap(RuleLoader.resourceURL("rules.uk"), "немає rules.uk.json")
        return try JSONDecoder().decode(RuleLoader.RuleTranslations.self, from: Data(contentsOf: url))
    }

    func testUkrainianTranslationCoversEveryBuiltinRuleAndGroup() throws {
        let english = try RuleLoader.builtin(language: .en)
        let uk = try ukrainianTranslations()

        XCTAssertEqual(Set(uk.groups.keys), Set(english.groups.map(\.id)), "групи в rules.uk.json не збігаються з rules.json")
        XCTAssertEqual(Set(uk.rules.keys), Set(english.rules.map(\.id)), "правила в rules.uk.json не збігаються з rules.json")
        for (id, title) in uk.groups {
            XCTAssertFalse(title.trimmingCharacters(in: .whitespaces).isEmpty, "група \(id): порожня назва")
        }
        for (id, texts) in uk.rules {
            XCTAssertFalse((texts.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty, "\(id): порожня назва")
            XCTAssertFalse((texts.detail ?? "").trimmingCharacters(in: .whitespaces).isEmpty, "\(id): порожній опис")
        }
    }

    func testEnglishRulesContainNoCyrillic() throws {
        let set = try RuleLoader.builtin(language: .en)
        func hasCyrillic(_ text: String) -> Bool {
            text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        }
        for group in set.groups {
            XCTAssertFalse(hasCyrillic(group.title), "група \(group.id): кирилиця в англійській назві")
        }
        for rule in set.rules {
            XCTAssertFalse(hasCyrillic(rule.title), "\(rule.id): кирилиця в англійській назві")
            XCTAssertFalse(hasCyrillic(rule.detail), "\(rule.id): кирилиця в англійському описі")
        }
    }

    func testRuleLanguageSwitchesTitlesAndDetails() throws {
        let english = try RuleLoader.builtin(language: .en)
        let ukrainian = try RuleLoader.builtin(language: .uk)
        XCTAssertEqual(english.rules.map(\.id), ukrainian.rules.map(\.id), "переклад не має міняти склад і порядок правил")
        XCTAssertEqual(english.groups.first { $0.id == "apps" }?.title, "App caches")
        XCTAssertEqual(ukrainian.groups.first { $0.id == "apps" }?.title, "Кеші застосунків")
        XCTAssertEqual(english.rules.first { $0.id == "system.trash" }?.title, "Trash")
        XCTAssertEqual(ukrainian.rules.first { $0.id == "system.trash" }?.title, "Кошик")
        // Everything except the texts is identical.
        for (en, uk) in zip(english.rules, ukrainian.rules) {
            XCTAssertEqual(en.paths, uk.paths, en.id)
            XCTAssertEqual(en.risk, uk.risk, en.id)
        }
        // load() with no arguments follows the current language (tests: Ukrainian).
        XCTAssertEqual(try RuleLoader.builtin().groups.first { $0.id == "apps" }?.title, "Кеші застосунків")
    }

    func testGlobExpansionAndTilde() throws {
        let home = try FakeHome()
        try home.makeFile("Library/Caches/Google/AndroidStudio1/a")
        try home.makeFile("Library/Caches/Google/AndroidStudio2/a")
        try home.makeFile("Library/Caches/Google/Chrome/a")
        let matches = PathExpander.expand("~/Library/Caches/Google/AndroidStudio*", home: home.url)
        XCTAssertEqual(Set(matches.map(\.lastPathComponent)), ["AndroidStudio1", "AndroidStudio2"])
        XCTAssertTrue(PathExpander.expand("~/nope/*", home: home.url).isEmpty)
    }
}
