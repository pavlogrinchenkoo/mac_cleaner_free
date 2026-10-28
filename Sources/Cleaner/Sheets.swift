import AppKit
import CleanerCore
import SwiftUI

struct CleaningSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Text(model.dryRun ? L("Dry run…") : L("Working…")).font(.title3.weight(.semibold))
            if let progress = model.cleanProgress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                Text(progress.current.isEmpty ? " " : progress.current)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(L("%ld of %ld", progress.done, progress.total))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }

            if model.collectingDiagnostics {
                VStack(spacing: 8) {
                    Text(L("This may take 1–2 minutes. The biggest folders are time-limited, and I don't measure cloud folders (iCloud)."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("Skip and save what I have")) { model.skipDiagnostics() }
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
                        Text(report.dryRun ? L("Would be freed") : L("Freed")).foregroundStyle(.secondary)
                        Text(Format.bytes(report.freedBytes)).font(.system(size: 30, weight: .semibold))
                    }
                }

                if report.trashedBytes > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(report.dryRun ? L("Would be in Trash: %@", Format.bytes(report.trashedBytes)) : L("In Trash: %@", Format.bytes(report.trashedBytes)), systemImage: "trash")
                            .font(.headline)
                        Text(L("This can be restored. Space is freed when you empty the Trash (there is a “Trash” item in the “System & logs” group)."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !report.dryRun, let before = model.diskBeforeClean, let after = model.disk {
                    Text(L("Free on disk: %@ → %@", Format.bytes(before.freeBytes), Format.bytes(after.freeBytes)))
                        .font(.callout)
                    Text(L("Finder may show slightly different numbers: macOS updates free space with a delay."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !report.failures.isEmpty {
                    ProblemList(title: L("Failed"), items: report.failures, color: .red)
                }
                if !report.skipped.isEmpty {
                    ProblemList(title: L("Skipped"), items: report.skipped, color: .orange)
                }

                if let log = report.logURL {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                        Label(report.dryRun ? L("Diagnostics saved") : L("Log saved"), systemImage: "doc.text")
                            .font(.headline)
                        Text(log.lastPathComponent).font(.callout.monospaced()).textSelection(.enabled)
                        Text(report.dryRun
                             ? L("It has the full list of what was found, installed apps and a map of used space. The file contains file and app names from this Mac: read it before sending, and do not post it publicly without removing anything private.")
                             : L("The log lists the paths of the processed items, so it contains file names from this Mac. Read it before sharing it, and do not post it publicly without removing anything private."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            ShareLink(item: log) { Label(L("Share…"), systemImage: "square.and.arrow.up") }
                            Button { NSWorkspace.shared.activateFileViewerSelecting([log]) } label: {
                                Label(L("Show in Finder"), systemImage: "folder")
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button(L("Done")) { dismiss() }
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
                    Text(L("Full Disk Access")).font(.title2.weight(.semibold))
                    Text(model.hasFullDiskAccess ? L("Permission granted.") : L("Permission not granted yet."))
                        .foregroundStyle(model.hasFullDiskAccess ? Color.green : Color.orange)
                }
            }

            Text(L("macOS doesn't let apps turn this access on themselves: you do it once in Settings. Without it I can't see the Trash and some protected folders, but everything else works."))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                step(1, L("Click “Open Settings”: Privacy & Security → Full Disk Access will open."))
                step(2, L("Turn on the switch next to Cleaner. If it isn't in the list, click “+” and add Cleaner.app. The “Show app in Finder” button helps you find it."))
                step(3, L("macOS will offer to quit and reopen the app: agree, or click “Restart” here. The permission doesn't work without a restart."))
            }

            HStack {
                Button(L("Open Settings")) { model.openFullDiskAccessSettings() }
                    .buttonStyle(.borderedProminent)
                Button(L("Show app in Finder")) { model.revealAppInFinder() }
                Spacer()
                if model.canRelaunch {
                    Button(L("Restart")) { model.relaunch() }
                }
                Button(model.hasFullDiskAccess ? L("Done") : L("Later")) {
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
