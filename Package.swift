// swift-tools-version: 6.0
import PackageDescription

// Three layers, each usable without the one above it:
//   DrillCore — timer engine, storage, stats, sync contract. No UI.
//   InkKit       — the hand-drawn ink design system. SwiftUI only.
//   DrillApp  — the macOS app that wires the two together.
// iOS (and anything else) later reuses Core + InkKit and adds its own shell.
let package = Package(
    name: "Drill",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "DrillCore", targets: ["DrillCore"]),
        .library(name: "InkKit", targets: ["InkKit"]),
        .executable(name: "Drill", targets: ["DrillApp"]),
    ],
    targets: [
        .target(name: "DrillCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "InkKit"),
        .executableTarget(name: "DrillApp", dependencies: ["DrillCore", "InkKit"]),
        // Renders Support/AppIcon.icns from the InkKit drill; see scripts/make-icon.sh.
        .executableTarget(name: "IconMaker", dependencies: ["InkKit"]),
        .testTarget(name: "DrillCoreTests", dependencies: ["DrillCore"]),
    ]
)
