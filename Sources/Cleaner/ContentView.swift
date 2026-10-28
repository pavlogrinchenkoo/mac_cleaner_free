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
                    ContentUnavailableView("Помилка", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if let id = model.selectedGroupID {
                    GroupDetailView(groupID: id)
                } else {
                    ContentUnavailableView("Нічого не вибрано", systemImage: "sidebar.left")
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
                    Label(model.phase == .scanning ? "Сканую…" : "Сканувати знову", systemImage: "arrow.clockwise")
                }
                .disabled(model.phase != .idle)
                .help("Заново порахувати, що можна почистити")
            }
        }
        .task {
            model.start()
            // Користувач міг відкрити чи закрити Xcode/Chrome: оновлюємо блокування.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await model.refreshRunning()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshSystemState()
        }
        .confirmationDialog(confirmTitle, isPresented: $model.showConfirm, titleVisibility: .visible) {
            Button(model.dryRun ? "Пробний запуск" : "Очистити", role: model.dryRun ? nil : .destructive) {
                model.clean()
            }
            Button("Скасувати", role: .cancel) {}
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
                ? "Пробний запуск: зберу діагностику"
                : "Пробний запуск: \(Format.itemCount(model.selectedEntries.count)), \(Format.bytes(model.selectedBytes))"
        }
        return "Очистити \(Format.itemCount(model.selectedEntries.count)), \(Format.bytes(model.selectedBytes))?"
    }

    private var confirmMessage: String {
        if model.dryRun {
            return "Нічого не буде видалено. Зберу звіт про те, що знайшов і що було б зроблено; його можна переслати розробнику."
        }
        var lines: [String] = []
        if model.selectedTrashCount > 0 {
            lines.append("У Кошик (можна повернути): \(Format.itemCount(model.selectedTrashCount)), \(Format.bytes(model.selectedTrashBytes)). Місце звільниться після очищення Кошика.")
        }
        let deleted = model.selectedEntries.count - model.selectedTrashCount
        if deleted > 0 {
            lines.append("Видалиться назовсім: \(Format.itemCount(deleted)), \(Format.bytes(model.selectedDeleteBytes)).")
        }
        if model.selectedAdminCount > 0 {
            lines.append("Для \(Format.itemCount(model.selectedAdminCount)) macOS попросить пароль адміна.")
        }
        if model.selectedPersonalCount > 0 {
            lines.append("⚠︎ Серед вибраного \(Format.itemCount(model.selectedPersonalCount)) особистих файлів, програм чи резервних копій: це твоя робота й дані. Перевір список ще раз.")
        } else if model.selectedCarefulCount > 0 {
            lines.append("Серед вибраного \(Format.itemCount(model.selectedCarefulCount)) з позначкою «Обережно».")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Сайдбар

/// Власний сайдбар на ScrollView, а не `List`: `List(.sidebar)` стоїть на NSTableView, який на старті
/// друкував попередження про реентерабельність (у майбутніх macOS воно стане помилкою).
private struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            DiskCard(disk: model.disk)
                .padding([.horizontal, .top], 12)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    Text("Що чистимо")
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
                    ProgressView("Шукаю…")
                }
            }
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
            // Груповий чекбокс вибирає лише рекомендоване; решту (файли, програми) вибирають по одному.
            TriStateBox(
                state: state,
                enabled: (model.phase == .idle || model.phase == .scanning) && model.hasRecommended(inGroup: group.id)
            ) {
                model.toggleGroup(group.id)
            }
            .help(model.hasRecommended(inGroup: group.id)
                  ? "Вибрати рекомендоване в цій групі"
                  : "Тут усе вибирається вручну")
            Image(systemName: group.symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.title).lineLimit(1)
                let selected = model.selectedBytes(inGroup: group.id)
                Text(selected > 0 ? "Вибрано \(Format.bytes(selected))" : "Нічого не вибрано")
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

// MARK: - Футер

private struct FooterBar: View {
    @Environment(AppModel.self) private var model

    private var selectionDetail: String {
        var detail = Format.itemCount(model.selectedEntries.count)
        if model.selectedTrashCount > 0 { detail += ", у Кошик: \(Format.bytes(model.selectedTrashBytes))" }
        if model.selectedPersonalCount > 0 { detail += ", особистих: \(model.selectedPersonalCount)" }
        else if model.selectedCarefulCount > 0 { detail += ", обережних: \(model.selectedCarefulCount)" }
        if model.phase == .scanning { detail += " · " + (model.statusText ?? "сканую…") }
        return detail
    }

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                if model.selectedEntries.isEmpty {
                    Text(model.phase == .scanning ? (model.statusText ?? "Сканую…") : "Нічого не вибрано")
                        .font(.headline)
                    if model.phase == .scanning, model.statusText != nil {
                        Text("Результати з'являються по ходу").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Вибрано \(Format.bytes(model.selectedBytes))").font(.headline)
                    Text(selectionDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Toggle("Пробний запуск", isOn: $model.dryRun)
                .toggleStyle(.switch)
                .help("Нічого не змінює, а збирає звіт про те, що було б зроблено")

            Button {
                model.showConfirm = true
            } label: {
                Label(model.dryRun ? "Перевірити" : "Очистити…", systemImage: model.dryRun ? "eye" : "trash")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(model.dryRun ? .accentColor : .red)
            // У пробному запуску кнопка активна й без вибору: вона збирає діагностику.
            .disabled(model.phase != .idle || (!model.dryRun && model.selectedEntries.isEmpty))
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

// MARK: - Банер Full Disk Access

private struct FullDiskAccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            Text("Без Full Disk Access я не бачу Кошик і частину захищених папок. Решта працює.")
                .font(.callout)
            Spacer()
            Button("Налаштувати…") { model.showFullDiskAccessGuide = true }
            Button("Перевірити знову") { model.refreshSystemState() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}
