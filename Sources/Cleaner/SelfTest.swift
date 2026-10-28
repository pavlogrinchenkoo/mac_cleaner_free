import AppKit
import CleanerCore

/// Безголовий режим самоперевірки: `Cleaner --selftest`.
/// Запускає справжню модель застосунку на реальних даних, робить ПРОБНИЙ запуск (нічого не видаляє),
/// перевіряє власну поведінку й пише звіт. Для швидкої перевірки без кліків: `scripts/selftest.sh`.
@MainActor
enum SelfTest {
    static var isRequested: Bool { CommandLine.arguments.contains("--selftest") }

    static func runIfRequested(model: AppModel) {
        guard isRequested else { return }
        // Сторож: якщо щось зависло, не лишаємо процес назавжди.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1500) {
            print("❌ ТАЙМАУТ: самоперевірка не завершилась за 25 хвилин")
            fflush(stdout)
            exit(2)
        }
        Task { @MainActor in
            let code = await run(model: model)
            fflush(stdout)
            exit(code)
        }
    }

    private static let personalScopes: Set<EntryScope> = [.userFile, .backup, .application]

    private static func wait(_ timeout: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return condition()
    }

    private static func format(_ bytes: Int64) -> String {
        bytes <= 0 ? "0 КБ" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func run(model: AppModel) async -> Int32 {
        var lines: [String] = []
        var failed = 0
        func check(_ ok: Bool, _ title: String, _ detail: String = "") {
            lines.append("\(ok ? "✅" : "❌") \(title)\(detail.isEmpty ? "" : ": \(detail)")")
            if !ok { failed += 1 }
        }
        func info(_ text: String) { lines.append("ℹ️  \(text)") }
        func emit() {
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            let text = lines.joined(separator: "\n") + "\n"
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cleaner/logs")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? text.write(to: dir.appendingPathComponent("selftest-\(stamp.string(from: Date())).txt"), atomically: true, encoding: .utf8)
            print(text)
        }

        info("Cleaner \(SystemDescription.appVersion), macOS \(SystemDescription.macOSVersion), Full Disk Access: \(FullDiskAccess.isGranted() ? "є" : "немає")")
        info("РЕЖИМ: лише пробний запуск, нічого не видаляється")

        // 1. Скан
        let scanStart = Date()
        model.start()
        let scanned = await wait(900) { model.phase == .idle && model.lastScan != nil }
        check(scanned, "Скан завершився", "\(Int(Date().timeIntervalSince(scanStart))) с")
        guard scanned else { emit(); return 1 }

        let all = model.allEntries
        let auto = model.selectedEntries
        let autoBytes = auto.reduce(Int64(0)) { $0 + $1.bytes }
        info("Знайдено \(all.count) елементів у \(model.results.filter { !$0.entries.isEmpty }.count) правилах; автоматично вибрано \(auto.count) (\(format(autoBytes)))")

        // 2. Автоматичний вибір має бути безпечним
        let personalAuto = auto.filter { personalScopes.contains($0.scope) }
        check(personalAuto.isEmpty, "Особисті файли, бекапи й програми не вибрано автоматично",
              personalAuto.prefix(3).map(\.name).joined(separator: ", "))
        let adminAuto = auto.filter { $0.scope == .system || (model.rule($0.ruleID)?.requiresAdmin ?? false) }
        check(adminAuto.isEmpty, "Нічого, що потребує пароля, не вибрано автоматично")
        check(auto.allSatisfy { model.blockReason($0) == nil }, "Серед вибраного немає заблокованого (запущені програми тощо)")
        let carefulAuto = auto.filter { entry in
            guard let rule = model.rule(entry.ruleID) else { return false }
            return rule.risk == .careful && rule.autoSelectOlderThanDays == nil
        }
        check(carefulAuto.isEmpty, "«Обережні» правила не вибрано автоматично", carefulAuto.prefix(3).map(\.name).joined(separator: ", "))
        check(model.manuallyChanged.isEmpty, "До дій користувача нічого не позначено як «вручну»")
        let blockedCount = all.filter { model.blockReason($0) != nil }.count
        info("Заблоковано зараз: \(blockedCount) елементів (запущені програми, остання версія тощо)")

        // 3. Пробний запуск № 1: такий самий, як натиснув би користувач (з картою місця)
        var previousLog = model.report?.logURL
        let dryStart = Date()
        model.dryRun = true
        model.diagnosticsSurveyEnabled = true
        model.clean()
        let firstDone = await wait(1200) { model.phase == .idle && model.report != nil && model.report?.logURL != previousLog }
        check(firstDone, "Пробний запуск № 1 завершився", "\(Int(Date().timeIntervalSince(dryStart))) с")
        guard firstDone, let first = model.report else { emit(); return 1 }
        let firstLog = first.logURL
        check(first.dryRun && first.failures.isEmpty, "У пробному запуску немає помилок", "помилок: \(first.failures.count), пропущено: \(first.skipped.count)")
        check(firstLog != nil && FileManager.default.fileExists(atPath: firstLog?.path ?? ""), "Діагностичний файл створено")
        if let firstLog, let text = try? String(contentsOf: firstLog, encoding: .utf8) {
            lines.append("ЛОГ: \(firstLog.path)")
            check(text.contains("== ПІДСУМОК ==") && text.contains("== КАРТА ЗАЙНЯТОГО МІСЦЯ =="), "У файлі є підсумок і карта місця", "\(text.utf8.count / 1024) КБ")
            check(text.contains("Додано ВРУЧНУ користувачем: 0 елементів"), "У файлі немає ручних змін (їх не було)")
            // Легенда у шапці теж містить ці слова, тому шукаємо позначку саме на початку рядка елемента.
            func entryLines(_ marker: String) -> Int { text.components(separatedBy: "\n").filter { $0.hasPrefix("  \(marker) ") && $0.dropFirst(marker.count + 3).first?.isNumber == true }.count }
            check(entryLines("[✓ ВРУЧНУ]") == 0 && entryLines("[✗ ЗНЯТО ВРУЧНУ]") == 0, "Жодного рядка елемента з позначкою «вручну»")
            check(entryLines("[✓ ???]") == 0 && !text.contains("з НЕВІДОМОЇ причини"), "Немає вибору з невідомої причини")
            check(text.contains("ВСТАНОВЛЕНІ ПРОГРАМИ"), "У файлі є список встановлених програм")
            check(!text.contains(" Zero KB"), "У файлі немає «Zero KB»")
        }

        // 4. Імітація дій користувача: клік по групі, по правилу «без масового вибору», по елементу
        let personalBefore = model.selectedEntries.filter { personalScopes.contains($0.scope) }.count
        for group in model.groups { model.toggleGroup(group.id) }
        let personalAfterGroups = model.selectedEntries.filter { personalScopes.contains($0.scope) }.count
        check(personalAfterGroups == personalBefore, "Груповий чекбокс не вибирає особисте", "до: \(personalBefore), після: \(personalAfterGroups)")
        for group in model.groups { model.toggleGroup(group.id) }   // повертаємо як було

        let nonBulk = model.results.first { !$0.rule.bulkSelectable && $0.entries.contains(where: model.isSelectable) }
        if let nonBulk {
            let snapshot = model.selected
            model.toggle(nonBulk)
            check(model.selected == snapshot, "«Вибрати все» вимкнено для «\(nonBulk.rule.title)»")
        } else {
            info("Немає правила без масового вибору з доступними елементами: перевірку пропущено")
        }

        let candidate = all.first { personalScopes.contains($0.scope) && model.isSelectable($0) }
        var manualPath: String?
        if let candidate {
            model.toggle(candidate)
            check(model.selected.contains(candidate.id) && model.manuallyChanged.contains(candidate.id),
                  "Ручний вибір особистого елемента працює й позначається як «вручну»", candidate.name)
            manualPath = candidate.url.path
        } else {
            info("На цьому Mac немає доступних особистих елементів: ручний вибір не перевірено")
        }

        // 5. Пробний запуск № 2 (без карти місця, швидко): у файлі має бути видно ручний вибір
        previousLog = model.report?.logURL
        model.diagnosticsSurveyEnabled = false
        model.clean()
        let secondDone = await wait(600) { model.phase == .idle && model.report?.logURL != previousLog }
        check(secondDone, "Пробний запуск № 2 завершився")
        if secondDone, let log = model.report?.logURL, let text = try? String(contentsOf: log, encoding: .utf8) {
            if manualPath != nil {
                func entryLines(_ marker: String) -> Int { text.components(separatedBy: "\n").filter { $0.hasPrefix("  \(marker) ") && $0.dropFirst(marker.count + 3).first?.isNumber == true }.count }
                check(entryLines("[✓ ВРУЧНУ]") == 1, "Файл позначає рівно один ручний вибір (`[✓ ВРУЧНУ]`)", "рядків: \(entryLines("[✓ ВРУЧНУ]"))")
                check(text.contains("Додано ВРУЧНУ користувачем: 1 елементів"), "Підсумок рахує ручні зміни (клік по групі туди й назад не рахується)")
                check(entryLines("[✓ ???]") == 0, "Ручний вибір не виглядає як помилка")
            }
            check(text.contains("[✓ авто]"), "Файл позначає автоматичний вибір (`[✓ авто]`)")
        }

        // 6. Нічого не видалено
        var missing: [String] = []
        for entry in all where entry.action == .removePaths || entry.action == .trashPaths {
            var st = stat()
            if lstat(entry.url.path, &st) != 0 { missing.append(entry.url.path) }
        }
        check(missing.isEmpty, "Після пробних запусків усе на місці", missing.prefix(3).joined(separator: ", "))

        lines.append("")
        lines.append(failed == 0 ? "РЕЗУЛЬТАТ: усі перевірки пройдено" : "РЕЗУЛЬТАТ: провалено перевірок — \(failed)")
        emit()
        return failed == 0 ? 0 : 1
    }
}
