import Darwin
import Foundation

public struct DiskInfo: Sendable, Equatable {
    public let totalBytes: Int64
    /// Free space as Finder reports it (including purgeable).
    public let freeBytes: Int64

    public var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
    public var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }

    public static func current(at url: URL = FileManager.default.homeDirectoryForCurrentUser) -> DiskInfo? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let free = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return DiskInfo(totalBytes: Int64(total), freeBytes: free)
    }
}

public enum FullDiskAccess {
    /// The system TCC database can only be read with Full Disk Access.
    public static func isGranted() -> Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

extension FullDiskAccess {
    /// Whether the error means "macOS denies access" (usually Full Disk Access is needed).
    public static func isDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError { return true }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EPERM) || nsError.code == Int(EACCES) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error, underlying as NSError != nsError {
            return isDenied(underlying)
        }
        return false
    }
}
