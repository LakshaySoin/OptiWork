// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FocusTrackerCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // The pure, deterministic tracking engine. No UI or OS dependency:
        // buildable and testable from the CLI with just the Swift toolchain.
        .library(name: "FocusTrackerCore", targets: ["FocusTrackerCore"]),
        // SQLite-backed production adapter of the `Store` seam (ADR-0006).
        .library(name: "FocusTrackerStore", targets: ["FocusTrackerStore"]),
        // OS adapters: frontmost/window-title/idle/blackout → Observations.
        .library(name: "FocusTrackerAdapter", targets: ["FocusTrackerAdapter"]),
        // The menu-bar application shell (ADR-0007).
        .executable(name: "ProductivityManager", targets: ["ProductivityManager"]),
    ],
    targets: [
        .target(
            name: "FocusTrackerCore",
            path: "Sources/FocusTrackerCore"
        ),
        .target(
            name: "FocusTrackerStore",
            dependencies: ["FocusTrackerCore"],
            path: "Sources/FocusTrackerStore"
        ),
        .target(
            name: "FocusTrackerAdapter",
            dependencies: ["FocusTrackerCore"],
            path: "Sources/FocusTrackerAdapter",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ProductivityManager",
            dependencies: ["FocusTrackerCore", "FocusTrackerStore", "FocusTrackerAdapter"],
            path: "Sources/ProductivityManager",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FocusTrackerCoreTests",
            dependencies: ["FocusTrackerCore"],
            path: "Tests/FocusTrackerCoreTests"
        ),
        .testTarget(
            name: "FocusTrackerStoreTests",
            dependencies: ["FocusTrackerCore", "FocusTrackerStore"],
            path: "Tests/FocusTrackerStoreTests"
        ),
        .testTarget(
            name: "FocusTrackerAdapterTests",
            dependencies: ["FocusTrackerCore", "FocusTrackerStore", "FocusTrackerAdapter"],
            path: "Tests/FocusTrackerAdapterTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)