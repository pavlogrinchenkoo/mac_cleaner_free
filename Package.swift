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
        // Рушій: правила, сканування, безпечне видалення. Без UI.
        .target(
            name: "CleanerCore",
            resources: [.copy("rules.json")]
        ),
        // Застосунок SwiftUI.
        .executableTarget(name: "Cleaner", dependencies: ["CleanerCore"]),
        // CLI для скриптів і перевірки рушія без UI.
        .executableTarget(name: "cleanerctl", dependencies: ["CleanerCore"]),
        .testTarget(name: "CleanerCoreTests", dependencies: ["CleanerCore"]),
    ]
)
