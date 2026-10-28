import XCTest
@testable import CleanerCore

final class DiskSizeTests: XCTestCase {
    func testMissingPathIsZero() {
        let result = DiskSize.measure(URL(fileURLWithPath: "/definitely/not/here-\(UUID().uuidString)"))
        XCTAssertEqual(result.bytes, 0)
        XCTAssertEqual(result.fileCount, 0)
    }

    func testCountsFilesRecursively() throws {
        let home = try FakeHome()
        try home.makeFile("a/one.bin", bytes: 100_000)
        try home.makeFile("a/b/two.bin", bytes: 200_000)
        let result = DiskSize.measure(home.path("a"))
        XCTAssertEqual(result.fileCount, 2)
        XCTAssertGreaterThanOrEqual(result.bytes, 300_000)
        XCTAssertLessThan(result.bytes, 400_000)
        XCTAssertNotNil(result.lastModified)
    }

    func testHardLinksCountedOnce() throws {
        let home = try FakeHome()
        let original = try home.makeFile("d/orig.bin", bytes: 500_000)
        try FileManager.default.linkItem(at: original, to: home.path("d/link.bin"))
        let result = DiskSize.measure(home.path("d"))
        XCTAssertEqual(result.fileCount, 1)
        XCTAssertLessThan(result.bytes, 600_000)
    }

    func testSymlinkIsNotFollowed() throws {
        let home = try FakeHome()
        let big = try FakeHome()
        try big.makeFile("huge.bin", bytes: 2_000_000)
        try FileManager.default.createDirectory(at: home.path("d"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.path("d/link"), withDestinationURL: big.url)
        XCTAssertLessThan(DiskSize.measure(home.path("d")).bytes, 100_000)
    }
}

final class CloudAndBudgetTests: XCTestCase {
    func testCloudProviderDirectoriesAreRecognized() {
        XCTAssertTrue(DiskSize.isCloudProviderDirectory("/Users/u/Library/Mobile Documents"))
        XCTAssertTrue(DiskSize.isCloudProviderDirectory("/Users/u/Library/Mobile Documents/iCloud~com~x/Documents"))
        XCTAssertTrue(DiskSize.isCloudProviderDirectory("/Users/u/Library/CloudStorage"))
        XCTAssertTrue(DiskSize.isCloudProviderDirectory("/Users/u/Library/CloudStorage/GoogleDrive-a@b.c/My Drive"))
        XCTAssertFalse(DiskSize.isCloudProviderDirectory("/Users/u/Library/Caches"))
        XCTAssertFalse(DiskSize.isCloudProviderDirectory("/Users/u/Documents/Mobile Documents"))
    }

    func testCloudDirectoryIsNeverMeasuredNorEntered() throws {
        let home = try FakeHome()
        try home.makeFile("Library/Mobile Documents/iCloud~app/Documents/big.bin", bytes: 400_000)
        try home.makeFile("Library/CloudStorage/Drive/file.bin", bytes: 400_000)
        try home.makeFile("Library/Caches/small.bin", bytes: 20_000)

        XCTAssertEqual(DiskSize.measure(home.path("Library/Mobile Documents")).bytes, 0)
        XCTAssertEqual(DiskSize.measure(home.path("Library/Mobile Documents/iCloud~app/Documents")).bytes, 0)
        // Обхід батьківської теки теж не заходить усередину.
        let library = DiskSize.measure(home.path("Library"))
        XCTAssertLessThan(library.bytes, 200_000, "вміст хмарних тек не врахований")
        XCTAssertGreaterThanOrEqual(library.bytes, 20_000)
    }

    func testExpiredDeadlineStopsMeasuringAndMarksIncomplete() throws {
        let home = try FakeHome()
        for i in 0..<50 { try home.makeFile("Dir/f\(i).bin", bytes: 10_000) }
        let result = DiskSize.measure(home.path("Dir"), deadline: Date(timeIntervalSinceNow: -5))
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(result.bytes, 500_000)
        XCTAssertFalse(DiskSize.measure(home.path("Dir")).timedOut, "без дедлайну міряє повністю")
    }

    func testSurveyMarksUnmeasuredCloudFoldersWithNote() throws {
        let home = try FakeHome()
        try home.makeFile("Library/Mobile Documents/iCloud~app/f.bin", bytes: 400_000)
        try home.makeFile("Library/Other/f.bin", bytes: 30_000)
        let library = home.path("Library")
        let directory = SurveyDirectory(
            title: "Library", url: library,
            unmeasured: [home.path("Library/Mobile Documents").path: "iCloud Drive: вміст не міряю"])
        let section = try XCTUnwrap(DiskSurvey.run(home: home.url, directories: [directory]).first)
        let cloud = try XCTUnwrap(section.items.first { $0.name == "Mobile Documents" })
        XCTAssertEqual(cloud.bytes, 0)
        XCTAssertEqual(cloud.note, "iCloud Drive: вміст не міряю")
        XCTAssertFalse(cloud.incomplete)
        XCTAssertGreaterThan(try XCTUnwrap(section.items.first { $0.name == "Other" }).bytes, 0)
    }

    func testSurveyItemBudgetMakesItemsIncompleteInsteadOfHanging() throws {
        let home = try FakeHome()
        for i in 0..<20 { try home.makeFile("Lib/item\(i)/a.bin", bytes: 10_000) }
        let started = Date()
        let section = try XCTUnwrap(DiskSurvey.run(
            home: home.url, directories: [SurveyDirectory(title: "Lib", url: home.path("Lib"))], itemBudget: -1).first)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertEqual(section.items.count, 20)
        XCTAssertTrue(section.items.allSatisfy(\.incomplete), "жоден елемент не встиг у нульовий бюджет")
    }

    func testSurveyTotalBudgetReturnsImmediatelyAndKeepsUnfinishedItems() throws {
        let home = try FakeHome()
        for i in 0..<30 { try home.makeFile("Lib/item\(i)/a.bin", bytes: 10_000) }
        let started = Date()
        let section = try XCTUnwrap(DiskSurvey.run(
            home: home.url, directories: [SurveyDirectory(title: "Lib", url: home.path("Lib"))], totalBudget: 0).first)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "не чекає на недороблене")
        XCTAssertEqual(section.totalCount, 30, "нічого не губимо")
        XCTAssertTrue(section.items.allSatisfy { $0.incomplete && $0.note != nil })
    }

    func testSurveyStopsWhenCancelled() throws {
        let home = try FakeHome()
        for i in 0..<30 { try home.makeFile("Lib/item\(i)/a.bin", bytes: 10_000) }
        let section = try XCTUnwrap(DiskSurvey.run(
            home: home.url, directories: [SurveyDirectory(title: "Lib", url: home.path("Lib"))], isCancelled: { true }).first)
        XCTAssertEqual(section.totalCount, 30)
        XCTAssertTrue(section.items.allSatisfy(\.incomplete))
    }

    func testReportShowsIncompleteSizesAndWarning() throws {
        let home = try FakeHome()
        let survey = [SurveySection(
            title: "~/Documents", path: "/d",
            items: [SurveyItem(name: "Huge", bytes: 3_000_000_000, lastModified: nil, incomplete: true),
                    SurveyItem(name: "Mobile Documents", bytes: 0, lastModified: nil, note: "iCloud Drive: вміст не міряю")],
            totalCount: 2, restBytes: 0, error: nil)]
        let input = DiagnosticInput(
            appVersion: "1", dryRun: true, macOSVersion: "26", architecture: "arm64", fullDiskAccess: true, disk: nil,
            projectRoots: [], fileSettings: nil, groups: [], results: [], selectedIDs: [], ruleBlocks: [:],
            blockReason: { _, _ in nil }, apps: [], survey: survey, home: home.url)
        let text = DiagnosticReport.render(input)
        XCTAssertTrue(text.contains("≥ 3 GB"), text)
        XCTAssertTrue(text.contains("Не всі розміри дорахувались (1)"))
        XCTAssertTrue(text.contains("iCloud Drive: вміст не міряю"))
    }
}
