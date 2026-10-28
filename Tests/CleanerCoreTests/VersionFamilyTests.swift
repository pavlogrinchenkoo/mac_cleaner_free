import XCTest
@testable import CleanerCore

final class VersionFamilyTests: CleanerTestCase {
    func testParsesFamilyAndVersion() {
        XCTAssertEqual(VersionedName("AndroidStudio2025.3.4")?.family, "AndroidStudio")
        XCTAssertEqual(VersionedName("AndroidStudio2025.3.4")?.version, [2025, 3, 4])
        XCTAssertEqual(VersionedName("WebStorm2026.1")?.version, [2026, 1])
        XCTAssertEqual(VersionedName("AndroidStudioPreview2026.2.1")?.family, "AndroidStudioPreview")
    }

    func testRejectsNamesWithoutVersion() {
        XCTAssertNil(VersionedName("Chrome"))
        XCTAssertNil(VersionedName("acp-agents"))
        XCTAssertNil(VersionedName("2026.1"))
        XCTAssertNil(VersionedName("consentOptions"))
    }

    func testVersionOrderingIsNumericNotLexical() {
        XCTAssertTrue(VersionedName.isNewer([2026, 2, 3], than: [2026, 2, 1]))
        XCTAssertTrue(VersionedName.isNewer([2026, 10], than: [2026, 9]))
        XCTAssertTrue(VersionedName.isNewer([2026, 2, 1], than: [2026, 2]))
        XCTAssertFalse(VersionedName.isNewer([2026, 2], than: [2026, 2]))
    }

    func testNewestPerFamily() {
        let newest = VersionFamily.newestPerFamily(names: [
            "AndroidStudio2025.3.4", "AndroidStudio2026.2.3", "AndroidStudio2026.1.4",
            "WebStorm2025.3", "WebStorm2026.2", "WebStorm2026.1", "Chrome",
        ])
        XCTAssertEqual(newest["AndroidStudio"], "AndroidStudio2026.2.3")
        XCTAssertEqual(newest["WebStorm"], "WebStorm2026.2")
        XCTAssertEqual(newest.count, 2)
    }
}
