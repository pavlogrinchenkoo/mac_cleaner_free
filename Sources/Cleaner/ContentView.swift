import AppKit
import CleanerCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            if !model.hasFullDiskAccess {
                FullDiskAccessBanner()
                Divider()
            }
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 360)
            } detail: {
                if let error = model.loadError {
                    ContentUnavailableView(L("Error"), systemImage: "exclamationmark.triangle", description: Text(error))
                } else if let id = model.selectedGroupID {
                    GroupDetailView(groupID: id)
                } else {
                    ContentUnavailableView(L("Nothing selected"), systemImage: "sidebar.left")
                }
            }
            Divider()
            FooterBar()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.scan()
                } label: {
                    Label(model.phase == .scanning ? L("Scanning…") : L("Scan again"), systemImage: "arrow.clockwise")
                }
                .disabled(model.phase != .idle)
                .help(L("Recount what can be cleaned"))
            }
        }
        .task {
            model.start()
            // The user may have opened or closed Xcode/Chrome: refresh the blocking.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await model.refreshRunning()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshSystemState()
        }
        .confirmationDialog(confirmTitle, isPresented: $model.showConfirm, titleVisibility: .visible) {
            Button(model.dryRun ? L("Dry run") : L("Clean"), role: model.dryRun ? nil : .destructive) {
                model.clean()
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .sheet(isPresented: Binding(get: { model.phase == .cleaning }, set: { _ in })) {
            CleaningSheet()
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $model.showReport) {
            ReportSheet()
        }
        .sheet(isPresented: $model.showFullDiskAccessGuide) {
            FullDiskAccessSheet()
        }
    }

    private var confirmTitle: String {
        if model.dryRun {
            return model.selectedEntries.isEmpty
                ? L("Dry run: I'll collect diagnostics")
                : L("Dry run: %@, %@", Format.itemCount(model.selectedEntries.count), Format.bytes(model.selectedBytes))
        }
        return L("Clean %@, %@?", Format.itemCount(model.selectedEntries.count), Format.bytes(model.selectedBytes))
    }

    private var confirmMessage: String {
        if model.dryRun {
            return L("Nothing will be deleted. I'll build a report of what I found and what would be done; you can send it to the developer.")
        }
        var lines: [String] = []
        if model.selectedTrashCount > 0 {
            lines.append(L("To Trash (recoverable): %@, %@. Space is freed after you empty the Trash.", Format.itemCount(model.selectedTrashCount), Format.bytes(model.selectedTrashBytes)))
        }
        let deleted = model.selectedEntries.count - model.selectedTrashCount
        if deleted > 0 {
            lines.append(L("Permanently deleted: %@, %@.", Format.itemCount(deleted), Format.bytes(model.selectedDeleteBytes)))
        }
        if model.selectedAdminCount > 0 {
            lines.append(L("For %@ macOS will ask for the administrator password.", Format.itemCount(model.selectedAdminCount)))
        }
        if model.selectedPersonalCount > 0 {
            lines.append(L("⚠︎ Your selection includes personal files, apps or backups (%@): this is your work and data. Check the list again.", Format.itemCount(model.selectedPersonalCount)))
        } else if model.selectedCarefulCount > 0 {
            lines.append(L("Your selection includes %@ marked “Careful”.", Format.itemCount(model.selectedCarefulCount)))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Sidebar

/// Custom sidebar built on ScrollView instead of `List`: `List(.sidebar)` sits on top of NSTableView, which printed
/// a reentrancy warning at launch (in future macOS versions it will become an error).
private struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            DiskCard(disk: model.disk)
                .padding([.horizontal, .top], 12)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    Text(L("What to clean"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)

                    ForEach(model.groups.filter(model.isGroupVisible)) { group in
                        GroupRow(group: group, isSelected: model.selectedGroupID == group.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .overlay {
                if model.phase == .scanning && model.results.isEmpty {
                    ProgressView(L("Searching…"))
                }
            }

            Divider()
            HStack {
                LanguageMenu()
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial)
    }
}

private struct GroupRow: View {
    @Environment(AppModel.self) private var model
    let group: CleanupGroup
    let isSelected: Bool

    var body: some View {
        let state = model.state(ofGroup: group.id)
        HStack(spacing: 10) {
            // The group checkbox selects only what is recommended; the rest (files, apps) is selected one by one.
            TriStateBox(
                state: state,
                enabled: (model.phase == .idle || model.phase == .scanning) && model.hasRecommended(inGroup: group.id)
            ) {
                model.toggleGroup(group.id)
            }
            .help(model.hasRecommended(inGroup: group.id)
                  ? L("Select the recommended items in this group")
                  : L("Everything here is selected manually"))
            Image(systemName: group.symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.title).lineLimit(1)
                let selected = model.selectedBytes(inGroup: group.id)
                Text(selected > 0 ? L("Selected %@", Format.bytes(selected)) : L("Nothing selected"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(Format.bytes(model.totalBytes(inGroup: group.id)))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { model.selectedGroupID = group.id }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @Environment(AppModel.self) private var model

    private var selectionDetail: String {
        var detail = Format.itemCount(model.selectedEntries.count)
        if model.selectedTrashCount > 0 { detail += L(", to Trash: %@", Format.bytes(model.selectedTrashBytes)) }
        if model.selectedPersonalCount > 0 { detail += L(", personal: %ld", model.selectedPersonalCount) }
        else if model.selectedCarefulCount > 0 { detail += L(", careful: %ld", model.selectedCarefulCount) }
        if model.phase == .scanning { detail += " · " + (model.statusText ?? L("scanning…")) }
        return detail
    }

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                if model.selectedEntries.isEmpty {
                    Text(model.phase == .scanning ? (model.statusText ?? L("Scanning…")) : L("Nothing selected"))
                        .font(.headline)
                    if model.phase == .scanning, model.statusText != nil {
                        Text(L("Results appear as they come in")).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(L("Selected %@", Format.bytes(model.selectedBytes))).font(.headline)
                    Text(selectionDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Toggle(L("Dry run"), isOn: $model.dryRun)
                .toggleStyle(.switch)
                .help(L("Changes nothing and builds a report of what would be done"))

            Button {
                model.showConfirm = true
            } label: {
                Label(model.dryRun ? L("Check") : L("Clean…"), systemImage: model.dryRun ? "eye" : "trash")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(model.dryRun ? .accentColor : .red)
            // In a dry run the button is enabled even with nothing selected: it collects diagnostics.
            .disabled(model.phase != .idle || (!model.dryRun && model.selectedEntries.isEmpty))
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

// MARK: - Full Disk Access banner

private struct FullDiskAccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            Text(L("Without Full Disk Access I can't see the Trash and some protected folders. Everything else works."))
                .font(.callout)
            Spacer()
            Button(L("Set up…")) { model.showFullDiskAccessGuide = true }
            Button(L("Check again")) { model.refreshSystemState() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}
