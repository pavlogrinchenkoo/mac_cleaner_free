import CleanerCore
import SwiftUI

/// Чекбокс із трьома станами (усі / частина / жоден).
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
        case .off: "Не вибрано"
        case .mixed: "Вибрано частково"
        case .on: "Вибрано"
        }
    }
}

struct RiskBadge: View {
    let risk: Risk

    var body: some View {
        Text(risk == .safe ? "Безпечно" : "Обережно")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(risk == .safe ? Color.green : Color.orange)
            .background((risk == .safe ? Color.green : Color.orange).opacity(0.14), in: Capsule())
    }
}

/// Скільки вільно на диску.
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
                    Text("вільно")
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: disk.usedFraction)
                    .tint(low ? .red : .accentColor)
                Text("Зайнято \(Format.bytes(disk.usedBytes)) з \(Format.bytes(disk.totalBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Диск недоступний").foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Тонка смужка, що показує частку елемента від найбільшого у списку.
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
