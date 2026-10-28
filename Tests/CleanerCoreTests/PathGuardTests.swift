import XCTest
@testable import CleanerCore

final class PathGuardTests: CleanerTestCase {
    func testAllowsKnownCachePaths() throws {
        let home = try FakeHome()
        let guardian = PathGuard(home: home.url)
        XCTAssertNoThrow(try guardian.validate(home.path("Library/Caches/Foo")))
        XCTAssertNoThrow(try guardian.validate(home.path(".npm/_cacache")))
        XCTAssertNoThrow(try guardian.validate(home.path("Library/Developer/Xcode/DerivedData/App-abc")))
        XCTAssertNoThrow(try guardian.validate(home.path(".Trash/old.txt")))
    }

    func testRejectsHomeItselfAndTopLevelFolders() throws {
        let home = try FakeHome()
        let guardian = PathGuard(home: home.url)
        XCTAssertThrowsError(try guardian.validate(home.url))
        XCTAssertThrowsError(try guardian.validate(home.path("Library")))
        XCTAssertThrowsError(try guardian.validate(home.path(".npm")))
    }

    func testRejectsProtectedContainers() throws {
        let home = try FakeHome()
        let guardian = PathGuard(home: home.url)
        for relative in ["Library/Caches", "Library/Logs", "Library/Application Support", "Library/Developer", ".Trash"] {
            XCTAssertThrowsError(try guardian.validate(home.path(relative)), relative)
        }
    }

    func testRejectsPersonalData() throws {
        let home = try FakeHome()
        let guardian = PathGuard(home: home.url)
        for relative in [
            "Documents", "Documents/project", "Desktop/file.txt", "Downloads/a.zip", "Pictures/Photos Library.photoslibrary",
            "Library/Mail/V10", "Library/Messages/chat.db", "Library/Keychains/login.keychain-db", ".ssh/id_ed25519",
            "Library/Mobile Documents/com~apple~CloudDocs/x", "Library/Application Support/MobileSync/Backup/abc",
        ] {
            XCTAssertThrowsError(try guardian.validate(home.path(relative)), relative)
        }
    }

    func testRejectsOutsideHome() throws {
        let home = try FakeHome()
        let guardian = PathGuard(home: home.url)
        XCTAssertThrowsError(try guardian.validate(URL(fileURLWithPath: "/etc/hosts")))
        XCTAssertThrowsError(try guardian.validate(URL(fileURLWithPath: "/Users/someoneelse/Library/Caches/x")))
        // Папка-сусід з тим самим префіксом імені не має проходити.
        let sibling = home.url.deletingLastPathComponent().appendingPathComponent(home.url.lastPathComponent + "-evil/Library/Caches/x")
        XCTAssertThrowsError(try guardian.validate(sibling))
    }

    func testRejectsParentTraversal() throws {
        let home = try FakeHome()
        let guardian = PathGuard(home: home.url)
        // standardizedFileURL схлопує `..`, тож це вже шлях поза Caches, у Documents.
        let sneaky = URL(fileURLWithPath: home.url.path + "/Library/Caches/../../Documents/x")
        XCTAssertThrowsError(try guardian.validate(sneaky))
    }

    func testRejectsParentSymlinkEscapingHome() throws {
        let home = try FakeHome()
        let outside = try FakeHome()
        try FileManager.default.createDirectory(at: home.path("Library"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.path("Library/Caches"), withDestinationURL: outside.url)
        let guardian = PathGuard(home: home.url)
        XCTAssertThrowsError(try guardian.validate(home.path("Library/Caches/Foo"))) { error in
            XCTAssertEqual(error as? GuardError, .escapesHome(home.path("Library/Caches/Foo").path))
        }
    }

    func testSymlinkEntryItselfIsAllowed() throws {
        // Сам symlink як елемент — ок: видалиться посилання, а не ціль.
        let home = try FakeHome()
        let target = try FakeHome()
        try FileManager.default.createDirectory(at: home.path("Library/Caches"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.path("Library/Caches/Link"), withDestinationURL: target.url)
        XCTAssertNoThrow(try PathGuard(home: home.url).validate(home.path("Library/Caches/Link")))
    }
}
