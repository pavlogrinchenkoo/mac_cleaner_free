import CleanerCore
import Foundation

// cleanerctl scan                      — показати, що можна почистити
// cleanerctl clean                     — пробний запуск (нічого не видаляє)
// cleanerctl clean --yes               — справді видалити те, що вибрано за замовчуванням
// cleanerctl clean --yes --risk all    — разом з 🟡 обережними (крім того, що потребує пароля, та особистих файлів, бекапів і програм)
// cleanerctl clean --rule <id> ...     — лише вказані правила (усе, що можна)
// cleanerctl diagnose [--out файл]     — повний пробний запуск + діагностичний файл (для налаштування правил)
// Додатково: --top N, --root <папка> (папки проєктів), --min-size <МБ> (великі файли), --no-files

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func values(for flag: String, in args: [String]) -> [String] {
    zip(args, args.dropFirst()).filter { $0.0 == flag }.map(\.1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first, ["scan", "clean", "diagnose"].contains(command) else {
    fail(L("Usage: cleanerctl scan | clean [--yes] [--risk safe|all] [--rule <id>]... | diagnose [--out file]\n  extra: --root <folder>  --min-size <MB>  --top N  --no-files"))
}

let confirm = args.contains("--yes")
let includeAll = values(for: "--risk", in: args).contains("all")
let onlyRules = Set(values(for: "--rule", in: args))
let topN = values(for: "--top", in: args).first.flatMap { Int($0) } ?? 6
let home = FileManager.default.homeDirectoryForCurrentUser
let explicitRoots = values(for: "--root", in: args).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
let projectRoots = explicitRoots.isEmpty ? ProjectRoots.detectDefaults(home: home) : explicitRoots

var fileSettings: FileScanSettings? = nil
if !args.contains("--no-files") {
    var settings = FileScanSettings(roots: FileScanSettings.defaultRoots(home: home), excludedRoots: projectRoots)
    if let mb = values(for: "--min-size", in: args).first.flatMap({ Int64($0) }) { settings.minLargeBytes = mb * 1_000_000 }
    fileSettings = settings
}

let ruleSet: RuleSet
do { ruleSet = try RuleLoader.load() } catch { fail(L("Could not read the rules: %@", "\(error)")) }

let scanner = DiskScanner(ruleSet: ruleSet, projectRoots: projectRoots, fileSettings: fileSettings)
var results: [String: RuleResult] = [:]
var order: [String] = []

for await event in scanner.scan() {
    switch event {
    case .discovered(let found):
        order = found.map(\.id)
        results = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
    case .appended(let found):
        for result in found {
            if results[result.id] == nil { order.append(result.id) }
            results[result.id] = result
        }
    case .measured(let id, let usage):
        for key in results.keys {
            if let index = results[key]?.entries.firstIndex(where: { $0.id == id }) {
                results[key]?.entries[index].measurement = usage
            }
        }
    case .status(let text):
        if let text { FileHandle.standardError.write(Data("… \(text)\n".utf8)) }
    case .finished:
        break
    }
}

let snapshot = RunningSnapshot.current()
let allRules = order.compactMap { results[$0]?.rule }
let ruleBlocks = DiskScanner.ruleBlocks(for: allRules, snapshot: snapshot)
let groupTitles = Dictionary(uniqueKeysWithValues: ruleSet.groups.map { ($0.id, $0.title) })
let groupOrder = ruleSet.groups.map(\.id)
let orderedIDs = order.enumerated().sorted { lhs, rhs in
    let l = groupOrder.firstIndex(of: results[lhs.element]?.rule.group ?? "") ?? 99
    let r = groupOrder.firstIndex(of: results[rhs.element]?.rule.group ?? "") ?? 99
    return l != r ? l < r : lhs.offset < rhs.offset
}.map(\.element)

@MainActor func blockReason(_ entry: Entry, _ rule: CleanupRule) -> String? {
    DiskScanner.blockReason(for: entry, rule: rule, ruleBlock: ruleBlocks[rule.id], snapshot: snapshot)
}

@MainActor func isSelectable(_ entry: Entry, in rule: CleanupRule) -> Bool {
    blockReason(entry, rule) == nil && entry.bytes > 0
}

@MainActor func ageText(_ entry: Entry) -> String {
    guard let date = entry.measurement?.lastModified else { return "" }
    return L("  (%@ %ld days ago)", entry.ageLabel ?? L("modified"), Int(Date().timeIntervalSince(date) / 86_400))
}

/// Те, що UI вибрав би за замовчуванням.
@MainActor func defaultSelection() -> [Entry] {
    orderedIDs.compactMap { results[$0] }.flatMap { result in
        result.entries.filter { isSelectable($0, in: result.rule) && DiskScanner.isSelectedByDefault($0, rule: result.rule) }
    }
}

if command == "scan" {
    var currentGroup = ""
    var totalDefault: Int64 = 0
    var totalOptional: Int64 = 0
    for id in orderedIDs {
        guard let result = results[id], result.entries.contains(where: { $0.bytes > 0 }) || result.accessError != nil else { continue }
        let rule = result.rule
        if rule.group != currentGroup {
            currentGroup = rule.group
            print("\n== \(groupTitles[rule.group] ?? rule.group) ==")
        }
        for entry in result.entries where isSelectable(entry, in: rule) {
            if DiskScanner.isSelectedByDefault(entry, rule: rule) { totalDefault += entry.bytes } else { totalOptional += entry.bytes }
        }
        let icon = rule.risk == .safe ? "🟢" : "🟡"
        let admin = rule.requiresAdmin ? " 🔑" : ""
        let trash = rule.moveToTrash ? L(" 🗑→Trash") : ""
        let blockNote = ruleBlocks[rule.id].map { L("  [blocked: %@]", $0) } ?? ""
        print("\(icon) \(rule.title)\(admin)\(trash)  \(Loc.bytes(result.entries.reduce(Int64(0)) { $0 + $1.bytes }))\(blockNote)")
        if let error = result.accessError { print("     ⚠︎ \(error)") }
        let shown = result.entries.sorted(by: { $0.bytes > $1.bytes }).filter { $0.bytes > 0 || $0.lockedReason != nil }
        for entry in shown.prefix(topN) {
            let note = blockReason(entry, rule).map { "  [\($0)]" } ?? ""
            let mark = DiskScanner.isSelectedByDefault(entry, rule: rule) && note.isEmpty ? "✓" : " "
            let size = entry.measurement == nil ? "—" : Loc.bytes(entry.bytes)
            let sub = entry.subtitle.flatMap { $0.isEmpty ? nil : "  · \($0)" } ?? ""
            print("   \(mark) \(size.padding(toLength: 10, withPad: " ", startingAt: 0))  \(entry.name)\(sub)\(ageText(entry))\(note)")
        }
        if shown.count > topN {
            let rest = shown.dropFirst(topN)
            print("     \(Loc.bytes(rest.reduce(Int64(0)) { $0 + $1.bytes }).padding(toLength: 10, withPad: " ", startingAt: 0))  \(L("... %ld more smaller ones", rest.count))")
        }
    }
    print(L("\nSelected by default (✓): %@   The rest is up to you: %@", Loc.bytes(totalDefault), Loc.bytes(totalOptional)))
    print(L("Project folders: %@", projectRoots.isEmpty ? L("not found (add --root <folder>)") : projectRoots.map { $0.path.replacingOccurrences(of: home.path, with: "~") }.joined(separator: ", ")))
    if let disk = DiskInfo.current() {
        print(L("Disk: %@ free of %@", Loc.bytes(disk.freeBytes), Loc.bytes(disk.totalBytes)))
    }
    exit(0)
}

if command == "diagnose" {
    let selected = defaultSelection()
    let engine = CleanEngine(safety: scanner.safety)
    let report = engine.clean(entries: selected, rules: allRules, dryRun: true)

    FileHandle.standardError.write(Data((L("… Collecting the disk usage map (up to a few minutes)") + "\n").utf8))
    let survey = DiskSurvey.run(home: home) { done, total in
        FileHandle.standardError.write(Data("… \(done)/\(total)\r".utf8))
    }

    let selectedIDs = Set(selected.map(\.id))
    let input = DiagnosticInput(
        appVersion: SystemDescription.appVersion, dryRun: true, macOSVersion: SystemDescription.macOSVersion,
        architecture: SystemDescription.architecture, fullDiskAccess: FullDiskAccess.isGranted(), disk: DiskInfo.current(),
        projectRoots: projectRoots, fileSettings: fileSettings, groups: ruleSet.groups,
        results: orderedIDs.compactMap { results[$0] }, selectedIDs: selectedIDs, ruleBlocks: ruleBlocks,
        blockReason: { [blocks = ruleBlocks, snap = snapshot] entry, rule in
            DiskScanner.blockReason(for: entry, rule: rule, ruleBlock: blocks[rule.id], snapshot: snap)
        },
        report: report,
        apps: DiagnosticReport.installedApps(roots: [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]),
        survey: survey, home: home)
    let text = DiagnosticReport.render(input)

    if let out = values(for: "--out", in: args).first {
        let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { fail(L("Could not write %@: %@", url.path, "\(error)")) }
        print(L("Diagnostics written: %@ (%ld KB)", url.path, text.utf8.count / 1024))
    } else if let url = DiagnosticReport.write(text, home: home) {
        print(L("Diagnostics written: %@ (%ld KB)", url.path, text.utf8.count / 1024))
    } else {
        fail(L("Could not write the diagnostics"))
    }
    exit(0)
}

// clean
var selected: [Entry] = []
for id in orderedIDs {
    guard let result = results[id] else { continue }
    let rule = result.rule
    for entry in result.entries where isSelectable(entry, in: rule) {
        let take: Bool
        if !onlyRules.isEmpty {
            take = onlyRules.contains(rule.id)
        } else if includeAll {
            // Особисті файли, бекапи й програми лише явно: `--rule <id>`.
            take = !rule.requiresAdmin && ![EntryScope.userFile, .backup, .application].contains(entry.scope)
        } else {
            take = DiskScanner.isSelectedByDefault(entry, rule: rule)
        }
        if take { selected.append(entry) }
    }
}

let total = selected.reduce(Int64(0)) { $0 + $1.bytes }
let needsPassword = selected.contains { $0.scope == .system || $0.needsAdmin }
print(confirm
    ? L("Running for %@ (%@)%@...", Loc.itemCount(selected.count), Loc.bytes(total), needsPassword ? L(", an administrator password will be requested") : "")
    : L("DRY RUN: %@ (%@). Nothing is changed; add --yes to run it for real.", Loc.itemCount(selected.count), Loc.bytes(total)))

let before = DiskInfo.current()
let engine = CleanEngine(safety: scanner.safety)
let report = engine.clean(entries: selected, rules: allRules, dryRun: !confirm) { done, total, current in
    if !current.isEmpty { print("[\(done + 1)/\(total)] \(current)") }
}

print("\n\(confirm ? L("Freed") : L("Would free")): \(Loc.bytes(report.freedBytes))   \(confirm ? L("In Trash") : L("Would be in Trash")): \(Loc.bytes(report.trashedBytes))")
for item in report.skipped { if case .skipped(let reason) = item.outcome { print(L("skipped (%@): %@", reason, item.path)) } }
for item in report.failures { if case .failed(let reason) = item.outcome { print(L("ERROR (%@): %@", reason, item.path)) } }
if let log = report.logURL { print(L("Log: %@", log.path)) }
if confirm, let before, let after = DiskInfo.current() {
    print(L("Free on disk: %@ → %@", Loc.bytes(before.freeBytes), Loc.bytes(after.freeBytes)))
}
