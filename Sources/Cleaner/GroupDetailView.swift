import AppKit
import CleanerCore
import SwiftUI

struct GroupDetailView: View {
    @Environment(AppModel.self) private var model
    let groupID: String

    var body: some View {
        let results = model.visibleResults(in: groupID)
        let title = model.groups.first { $0.id == groupID }?.title ?? ""

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.largeTitle.weight(.semibold))
                    Spacer()
                    Text(Format.bytes(model.totalBytes(inGroup: groupID)))
                        .font(.title2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)

                if groupID == AppModel.projectsGroupID {
                    ProjectRootsCard()
                }
                if groupID == AppModel.filesGroupID {
                    FileSettingsCard()
                }

                if results.isEmpty {
                    let isProjects = groupID == AppModel.projectsGroupID
                    let isFiles = groupID == AppModel.filesGroupID
                    ContentUnavailableView(
                        model.phase == .scanning ? "Шукаю…" : (isProjects ? "Артефактів не знайшов" : (isFiles ? "Нічого великого не знайшов" : "Тут чисто")),
                        systemImage: model.phase == .scanning ? "magnifyingglass" : (isProjects ? "folder" : "checkmark.circle"),
                        description: Text(model.phase == .scanning ? (model.statusText ?? "") : (isProjects
                            ? "Додай папку з проєктами вище, і я знайду в ній node_modules, build, Pods…"
                            : (isFiles ? "Спробуй зменшити поріг розміру вище." : "У цій групі немає чого чистити.")))
                    )
                    .frame(maxWidth: .infinity, minHeight: 200)
                }

                ForEach(results) { result in
                    RuleSection(result: result)
                }
            }
            .padding(20)
        }
    }
}

private struct RuleSection: View {
    @Environment(AppModel.self) private var model
    let result: RuleResult
    @State private var expanded = false
    @State private var showAll = false

    private static let collapsedLimit = 40

    var body: some View {
        let rule = result.rule
        let entries = model.visibleEntries(of: result)
        let state = model.state(of: result)
        let blocked = model.ruleBlocks[rule.id]
        let canBulk = model.canBulkSelect(result)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TriStateBox(state: state, enabled: canBulk) { model.toggle(result) }
                    .help(rule.bulkSelectable ? "Вибрати все в цьому правилі" : "Це твої файли: вибирай кожен окремо")
                Button {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Text(rule.title).font(.headline)
                        RiskBadge(risk: rule.risk)
                        if rule.requiresAdmin {
                            Label("потрібен пароль", systemImage: "key.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if rule.moveToTrash {
                            Label("у Кошик", systemImage: "trash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help("Можна повернути з Кошика. Місце звільниться після його очищення.")
                        }
                        if model.isMeasuring(result) {
                            ProgressView().controlSize(.small)
                        }
                        Spacer()
                        Text(Format.bytes(model.totalBytes(of: result)))
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(model.totalBytes(of: result) == 0 ? .secondary : .primary)
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Text(rule.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 30)

            if !rule.bulkSelectable {
                Label("Вибирай по одному: «вибрати все» тут вимкнено.", systemImage: "hand.raised")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 30)
            }

            if let days = rule.autoSelectOlderThanDays {
                Label("За замовчуванням вибрано те, де нічого не змінювалось \(days)+ днів. Решту обираєш сам.",
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 30)
            }

            if let blocked {
                Label(blocked, systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.leading, 30)
            }

            if let error = result.accessError {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Button("Налаштування") { model.openFullDiskAccessSettings() }
                        .controlSize(.small)
                }
                .padding(.leading, 30)
            }

            if expanded {
                let shown = showAll ? entries : Array(entries.prefix(Self.collapsedLimit))
                let maxBytes = max(entries.map(\.bytes).max() ?? 1, 1)

                VStack(spacing: 0) {
                    ForEach(shown) { entry in
                        EntryRow(entry: entry, fraction: Double(entry.bytes) / Double(maxBytes))
                        if entry.id != shown.last?.id { Divider().padding(.leading, 30) }
                    }
                    if entries.count > shown.count {
                        let rest = entries.dropFirst(shown.count)
                        Button("Показати ще \(Format.itemCount(rest.count)) (\(Format.bytes(rest.reduce(0) { $0 + $1.bytes })))") {
                            showAll = true
                        }
                        .buttonStyle(.link)
                        .padding(.leading, 30)
                        .padding(.top, 8)
                    }
                }
                .padding(.top, 4)
                .transition(.opacity)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct EntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: Entry
    let fraction: Double

    /// «node_modules · активність 3 міс. тому», «iOS 17.5 · запускався 2 міс. тому».
    private var detailLine: String? {
        var parts: [String] = []
        if let subtitle = entry.subtitle { parts.append(subtitle) }
        if let age = Format.age(entry.measurement?.lastModified) {
            parts.append("\(entry.ageLabel ?? "змінено") \(age)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        let reason = model.blockReason(entry)
        let measuring = entry.measurement == nil && entry.lockedReason == nil

        HStack(spacing: 10) {
            TriStateBox(state: model.selected.contains(entry.id) ? .on : .off, enabled: model.isSelectable(entry)) {
                model.toggle(entry)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(reason == nil ? .primary : .secondary)
                if let reason {
                    Label(reason, systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                // Підзаголовок лишається й у заблокованих рядках: за ним відрізняють однойменні програми.
                if let line = detailLine {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if measuring {
                ProgressView().controlSize(.mini)
            } else if entry.measurement != nil {
                SizeBar(fraction: fraction).frame(width: 70)
                Text(Format.bytes(entry.bytes))
                    .font(.callout.monospacedDigit())
                    .frame(width: 80, alignment: .trailing)
            } else {
                Text("—").foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Показати у Finder") { model.revealInFinder(entry) }
            Button("Скопіювати шлях") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.url.path, forType: .string)
            }
        }
        .help(entry.url.path)
    }
}

private struct ProjectRootsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Папки з проєктами", systemImage: "folder.badge.gearshape").font(.headline)
                Spacer()
                Button("Додати папку…", action: pickFolders)
                    .disabled(model.phase == .cleaning)
            }

            if model.projectRoots.isEmpty {
                Text("Додай папку, де лежать твої проєкти (наприклад ~/Developer). Я шукатиму в ній відновлювані теки й нічого більше не чіпатиму.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(model.projectRoots, id: \.path) { root in
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(abbreviated(root)).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button {
                        model.removeProjectRoot(root)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Більше не шукати в цій папці")
                }
            }

            if let message = model.rootsMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Text("Видаляю лише теки node_modules, build, Pods та подібні, і лише там, де поруч є файли проєкту (package.json, Podfile, pubspec.yaml…). Код ніколи не чіпаю.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func abbreviated(_ url: URL) -> String {
        url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private func pickFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Додати"
        panel.message = "Виберіть папки, де лежать ваші проєкти"
        if panel.runModal() == .OK { model.addProjectRoots(panel.urls) }
    }
}

private struct FileSettingsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Пошук файлів", systemImage: "magnifyingglass").font(.headline)
                Spacer()
                Picker("Великі файли від", selection: Binding(
                    get: { model.largeFileMinMB },
                    set: { model.setLargeFileMinMB($0) }
                )) {
                    ForEach(AppModel.minSizeOptionsMB, id: \.self) { mb in
                        Text(mb >= 1000 ? "1 ГБ" : "\(mb) МБ").tag(mb)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(model.phase == .cleaning)
            }

            Text("Шукаю у Downloads, Desktop, Documents, Movies, Music, Pictures. Приховане, програми, бібліотеки (Photos, Final Cut), git-репозиторії та папки проєктів не чіпаю.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Label("Усе тут переміщується в Кошик і ніколи не вибирається саме: обираєш ти. У дублікатів один оригінал завжди лишається.",
                  systemImage: "hand.raised")
                .font(.callout)
                .foregroundStyle(.secondary)

            if !model.hasFullDiskAccess {
                Label("Без Full Disk Access macOS може приховати від мене частину Downloads, Desktop і Documents.",
                      systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}
