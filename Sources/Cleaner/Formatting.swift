import CleanerCore
import Foundation

enum Format {
    static func bytes(_ value: Int64) -> String {
        Loc.bytes(value)
    }

    static func age(_ date: Date?) -> String? {
        guard let date else { return nil }
        if Date().timeIntervalSince(date) < 86_400 { return L("today") }
        // Створюємо на місці: мова може змінитися під час роботи, а виклики рідкі (рядки списку).
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Loc.current.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func itemCount(_ n: Int) -> String {
        Loc.itemCount(n)
    }
}
