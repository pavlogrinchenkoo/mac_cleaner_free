import Foundation

enum Format {
    static func bytes(_ value: Int64) -> String {
        // Без цього вийшло б «Zero KB».
        if value <= 0 { return "0 КБ" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    // Використовується лише з головного потоку (рендер SwiftUI).
    nonisolated(unsafe) private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "uk_UA")
        formatter.unitsStyle = .short
        return formatter
    }()

    static func age(_ date: Date?) -> String? {
        guard let date else { return nil }
        if Date().timeIntervalSince(date) < 86_400 { return "сьогодні" }
        return relative.localizedString(for: date, relativeTo: Date())
    }

    static func itemCount(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "\(n) елемент" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "\(n) елементи" }
        return "\(n) елементів"
    }
}
