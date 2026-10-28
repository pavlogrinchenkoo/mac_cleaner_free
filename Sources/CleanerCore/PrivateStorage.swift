import Foundation

/// Логи й діагностика містять назви файлів і програм користувача, тому читати їх може лише він сам:
/// тека 0700, файл 0600 (за замовчуванням файли створюються з правами 0644).
public enum PrivateStorage {
    public static func write(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Тека могла існувати раніше з правами за замовчуванням: затягуємо її та батьківську `Cleaner`.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.deletingLastPathComponent().path)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
