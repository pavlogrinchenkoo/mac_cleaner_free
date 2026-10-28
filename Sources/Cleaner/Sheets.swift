import AppKit
import CleanerCore
import SwiftUI

struct CleaningSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Text(model.dryRun ? "Пробний запуск…" : "Виконую…").font(.title3.weight(.semibold))
            if let progress = model.cleanProgress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                Text(progress.current.isEmpty ? " " : progress.current)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(progress.done) з \(progress.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }

            if model.collectingDiagnostics {
                VStack(spacing: 8) {
                    Text("Це може тривати 1–2 хвилини. Найбільші теки обмежені в часі, а хмарні (iCloud) не міряю.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Пропустити й зберегти те, що є") { model.skipDiagnostics() }
                }
            }
        }
        .padding(28)
        .frame(width: 440)
    }
}

struct ReportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let report = model.report {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: report.dryRun ? "eye.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(report.dryRun ? Color.accentColor : Color.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.dryRun ? "Було б звільнено" : "Звільнено").foregroundStyle(.secondary)
                        Text(Format.bytes(report.freedBytes)).font(.system(size: 30, weight: .semibold))
                    }
                }

                if report.trashedBytes > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("\(report.dryRun ? "Було б у Кошику" : "У Кошику"): \(Format.bytes(report.trashedBytes))", systemImage: "trash")
                            .font(.headline)
                        Text("Це можна повернути. Місце звільниться, коли очистиш Кошик (у групі «Система» є пункт «Кошик»).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !report.dryRun, let before = model.diskBeforeClean, let after = model.disk {
                    Text("Вільно на диску: \(Format.bytes(before.freeBytes)) → \(Format.bytes(after.freeBytes))")
                        .font(.callout)
                    Text("Finder може показати трохи інше: macOS оновлює вільне місце із затримкою.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !report.failures.isEmpty {
                    ProblemList(title: "Не вдалося", items: report.failures, color: .red)
                }
                if !report.skipped.isEmpty {
                    ProblemList(title: "Пропущено", items: report.skipped, color: .orange)
                }

                if let log = report.logURL {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                        Label(report.dryRun ? "Діагностику збережено" : "Лог збережено", systemImage: "doc.text")
                            .font(.headline)
                        Text(log.lastPathComponent).font(.callout.monospaced()).textSelection(.enabled)
                        if report.dryRun {
                            Text("Тут повний список знайденого, встановлені програми й карта зайнятого місця. У файлі є назви файлів і програм: за потреби перегляньте його перед відправкою.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            ShareLink(item: log) { Label("Поділитися…", systemImage: "square.and.arrow.up") }
                            Button { NSWorkspace.shared.activateFileViewerSelecting([log]) } label: {
                                Label("Показати у Finder", systemImage: "folder")
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Готово") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 540)
        }
    }
}

private struct ProblemList: View {
    let title: String
    let items: [CleanItemResult]
    let color: Color

    var body: some View {
        DisclosureGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.path).font(.caption).lineLimit(1).truncationMode(.middle)
                            Text(reason(item)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
        } label: {
            Label("\(title): \(items.count)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(color)
        }
    }

    private func reason(_ item: CleanItemResult) -> String {
        switch item.outcome {
        case .skipped(let text), .failed(let text): text
        default: ""
        }
    }
}

/// Пояснення, як дати Full Disk Access. Дозвіл не можна «запитати» діалогом: macOS вмикає його лише вручну в налаштуваннях.
struct FullDiskAccessSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: model.hasFullDiskAccess ? "checkmark.shield.fill" : "lock.shield.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(model.hasFullDiskAccess ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Повний доступ до диска").font(.title2.weight(.semibold))
                    Text(model.hasFullDiskAccess ? "Дозвіл є." : "Дозволу ще немає.")
                        .foregroundStyle(model.hasFullDiskAccess ? Color.green : Color.orange)
                }
            }

            Text("macOS не дозволяє застосункам вмикати цей доступ самим: це робиш ти один раз у налаштуваннях. Без нього я не бачу Кошик і частину захищених папок, але решта працює.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                step(1, "Натисни «Відкрити налаштування»: відкриється Конфіденційність і безпека → Повний доступ до диска.")
                step(2, "Увімкни перемикач біля Cleaner. Якщо його немає в списку, натисни «+» і додай Cleaner.app. Кнопка «Показати в Finder» допоможе його знайти.")
                step(3, "macOS запропонує закрити й відкрити застосунок знову: погодься або натисни «Перезапустити» тут. Без перезапуску дозвіл не діє.")
            }

            HStack {
                Button("Відкрити налаштування") { model.openFullDiskAccessSettings() }
                    .buttonStyle(.borderedProminent)
                Button("Показати в Finder") { model.revealAppInFinder() }
                Spacer()
                if model.canRelaunch {
                    Button("Перезапустити") { model.relaunch() }
                }
                Button(model.hasFullDiskAccess ? "Готово" : "Пізніше") {
                    model.dismissFullDiskAccessGuide()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 620)
        .task {
            // Поки аркуш відкритий, стежимо за станом дозволу.
            while !Task.isCancelled {
                model.refreshSystemState()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.18), in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
