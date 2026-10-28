import Foundation

/// Logs and diagnostics contain the names of the user's files and apps, so only the user may read them:
/// directory 0700, file 0600 (files are created with permissions 0644 by default).
public enum PrivateStorage {
    public static func write(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // The directory may already exist with default permissions: tighten it and its parent `Cleaner`.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.deletingLastPathComponent().path)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
