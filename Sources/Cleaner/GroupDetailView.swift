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
                        model.phase == .scanning ? L("Searching…") : (isProjects ? L("No artifacts found") : (isFiles ? L("No large files found") : L("All clean here"))),
                        systemImage: model.phase == .scanning ? "magnifyingglass" : (isProjects ? "folder" : "checkmark.circle"),
                        description: Text(model.phase == .scanning ? (model.statusText ?? "") : (isProjects
                            ? L("Add a projects folder above and I'll look for node_modules, build, Pods… in it.")
                            : (isFiles ? L("Try lowering the size threshold above.") : L("There is nothing to clean in this group."))))
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
                    .help(rule.bulkSelectable ? L("Select everything in this rule") : L("These are your files: select each one separately"))
                Button {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Text(rule.title).font(.headline)
                        RiskBadge(risk: rule.risk)
                        if rule.requiresAdmin {
                            Label(L("password required"), systemImage: "key.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if rule.moveToTrash {
                            Label(L("to Trash"), systemImage: "trash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help(L("Can be restored from the Trash. Space is freed after you empty it."))
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
                Label(L("Select one by one: “select all” is disabled here."), systemImage: "hand.raised")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 30)
            }

            if let days = rule.autoSelectOlderThanDays {
                Label(L("By default, items untouched for %ld+ days are selected. You choose the rest.", days),
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
                    Button(L("Settings")) { model.openFullDiskAccessSettings() }
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
                        Button(L("Show more: %@ (%@)", Format.itemCount(rest.count), Format.bytes(rest.reduce(0) { $0 + $1.bytes }))) {
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
            parts.append("\(entry.ageLabel ?? L("modified")) \(age)")
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
            Button(L("Show in Finder")) { model.revealInFinder(entry) }
            Button(L("Copy path")) {
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
                Label(L("Project folders"), systemImage: "folder.badge.gearshape").font(.headline)
                Spacer()
                Button(L("Add folder…"), action: pickFolders)
                    .disabled(model.phase == .cleaning)
            }

            if model.projectRoots.isEmpty {
                Text(L("Add the folder where your projects live (for example ~/Developer). I'll look in it for rebuildable folders and won't touch anything else."))
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
                    .help(L("Stop searching in this folder"))
                }
            }

            if let message = model.rootsMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Text(L("I only delete folders like node_modules, build, Pods, and only where project files sit next to them (package.json, Podfile, pubspec.yaml…). I never touch your code."))
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
        panel.prompt = L("Add")
        panel.message = L("Choose the folders where your projects live")
        if panel.runModal() == .OK { model.addProjectRoots(panel.urls) }
    }
}

private struct FileSettingsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L("File search"), systemImage: "magnifyingglass").font(.headline)
                Spacer()
                Picker(L("Large files from"), selection: Binding(
                    get: { model.largeFileMinMB },
                    set: { model.setLargeFileMinMB($0) }
                )) {
                    ForEach(AppModel.minSizeOptionsMB, id: \.self) { mb in
                        Text(Loc.bytes(Int64(mb) * 1_000_000)).tag(mb)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(model.phase == .cleaning)
            }

            Text(L("I search Downloads, Desktop, Documents, Movies, Music and Pictures. I don't touch hidden files, apps, libraries (Photos, Final Cut), git repositories or project folders."))
                .font(.callout)
                .foregroundStyle(.secondary)

            Label(L("Everything here is moved to the Trash and is never selected automatically: you choose. For duplicates, one original always stays."),
                  systemImage: "hand.raised")
                .font(.callout)
                .foregroundStyle(.secondary)

            if !model.hasFullDiskAccess {
                Label(L("Without Full Disk Access macOS may hide part of Downloads, Desktop and Documents from me."),
                      systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}
