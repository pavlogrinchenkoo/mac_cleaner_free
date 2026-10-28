import CleanerCore
import SwiftUI

/// Checkbox with three states (all / some / none).
struct TriStateBox: View {
    let state: TriState
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(state == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }

    private var symbol: String {
        switch state {
        case .off: "square"
        case .mixed: "minus.square.fill"
        case .on: "checkmark.square.fill"
        }
    }

    private var label: String {
        switch state {
        case .off: L("Not selected")
        case .mixed: L("Partially selected")
        case .on: L("Selected")
        }
    }
}

struct RiskBadge: View {
    let risk: Risk

    var body: some View {
        Text(risk == .safe ? L("Safe") : L("Careful"))
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(risk == .safe ? Color.green : Color.orange)
            .background((risk == .safe ? Color.green : Color.orange).opacity(0.14), in: Capsule())
    }
}

/// How much free space is left on the disk.
struct DiskCard: View {
    let disk: DiskInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let disk {
                let low = Double(disk.freeBytes) / Double(max(disk.totalBytes, 1)) < 0.10
                HStack(alignment: .firstTextBaseline) {
                    Text(Format.bytes(disk.freeBytes))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(low ? Color.red : Color.primary)
                    Text(L("free"))
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: disk.usedFraction)
                    .tint(low ? .red : .accentColor)
                Text(L("Used %@ of %@", Format.bytes(disk.usedBytes), Format.bytes(disk.totalBytes)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L("Disk unavailable")).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Thin bar showing an item's share relative to the largest one in the list.
struct SizeBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color.accentColor.opacity(0.55))
                    .frame(width: max(2, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}

/// Interface language picker: "System", English, Ukrainian. Language names are shown in their own languages.
struct LanguageMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Picker(L("Language"), selection: Binding(
                get: { model.languageChoice },
                set: { model.setLanguageChoice($0) }
            )) {
                ForEach(AppModel.LanguageChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(model.language.nativeName, systemImage: "globe")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.phase == .cleaning)
        .help(L("Language"))
    }
}
