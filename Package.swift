// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cleaner",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Cleaner", targets: ["Cleaner"]),
        .executable(name: "cleanerctl", targets: ["cleanerctl"]),
    ],
    targets: [
        // Engine: rules, scanning, safe deletion. No UI.
        .target(
            name: "CleanerCore",
            resources: [.copy("rules.json"), .copy("rules.uk.json")]
        ),
        // The SwiftUI app.
        .executableTarget(name: "Cleaner", dependencies: ["CleanerCore"]),
        // Command-line tool for scripts and checking the engine without the UI.
        .executableTarget(name: "cleanerctl", dependencies: ["CleanerCore"]),
        .testTarget(name: "CleanerCoreTests", dependencies: ["CleanerCore"]),
    ]
)
