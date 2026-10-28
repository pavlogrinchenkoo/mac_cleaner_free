import Darwin
import Foundation

/// Вимірює розмір на диску через `fts` — так само швидко, як `du`.
public enum DiskSize {
    private struct FileID: Hashable {
        let dev: Int32
        let ino: UInt64
    }

    /// Хмарні сховища (iCloud Drive, Google Drive тощо). Читання їхнього вмісту йде через службу синхронізації
    /// і може зависати надовго, тому їх не міряємо й не обходимо ніколи.
    public static func isCloudProviderDirectory(_ path: String) -> Bool {
        path.hasSuffix("/Library/Mobile Documents") || path.hasSuffix("/Library/CloudStorage")
            || path.contains("/Library/Mobile Documents/") || path.contains("/Library/CloudStorage/")
    }

    /// Розмір `url` (файл чи папка, без переходу за symlink-ами і на інші томи).
    /// Повертає `.zero`, якщо шляху не існує. Після `deadline` припиняє й ставить `timedOut`.
    public static func measure(_ url: URL, deadline: Date? = nil) -> DiskUsage {
        var result = DiskUsage.zero
        if isCloudProviderDirectory(url.path) { return result }
        var newest: Int = 0
        var seenLinks = Set<FileID>()

        let cPath: UnsafeMutablePointer<CChar>? = strdup(url.path)
        defer { free(cPath) }
        guard cPath != nil else { return result }

        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            result.hadErrors = true
            return result
        }
        defer { fts_close(stream) }

        var visited = 0
        while let ent = fts_read(stream) {
            visited += 1
            if visited % 2048 == 0, Task.isCancelled { break }
            if let deadline, visited % 256 == 1, Date() >= deadline {
                result.timedOut = true
                break
            }

            let info = Int32(ent.pointee.fts_info)
            switch info {
            case FTS_DP:
                // Папку рахуємо один раз, при вході (FTS_D), а не при виході.
                continue
            case FTS_D, FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let st = ent.pointee.fts_statp?.pointee else { continue }
                if info == FTS_D {
                    // Не заходимо в хмарні теки й теки-заглушки iCloud (їх вміст не на диску).
                    let path = String(cString: ent.pointee.fts_path)
                    if isCloudProviderDirectory(path) || (st.st_flags & 0x4000_0000) != 0 {
                        fts_set(stream, ent, FTS_SKIP)
                    }
                }
                // Hard link-и однієї речі рахуємо один раз.
                if st.st_nlink > 1 && (st.st_mode & S_IFMT) != S_IFDIR {
                    if !seenLinks.insert(FileID(dev: st.st_dev, ino: st.st_ino)).inserted { continue }
                }
                result.bytes += Int64(st.st_blocks) * 512
                if (st.st_mode & S_IFMT) != S_IFDIR { result.fileCount += 1 }
                let mtime = Int(st.st_mtimespec.tv_sec)
                if mtime > newest { newest = mtime }
            case FTS_DNR, FTS_ERR, FTS_NS, FTS_NSOK:
                // Немає доступу або файл зник посеред сканування.
                if ent.pointee.fts_errno == EACCES || ent.pointee.fts_errno == EPERM {
                    result.hadErrors = true
                }
            default:
                break
            }
        }

        if newest > 0 { result.lastModified = Date(timeIntervalSince1970: TimeInterval(newest)) }
        return result
    }
}
