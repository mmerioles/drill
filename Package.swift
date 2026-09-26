// swift-tools-version: 6.0
import PackageDescription

// Three layers, each usable without the one above it:
//   TetodoroCore — timer engine, storage, stats, sync contract. No UI.
//   InkKit       — the hand-drawn ink design system. SwiftUI only.
//   TetodoroApp  — the macOS app that wires the two together.
// iOS (and anything else) later reuses Core + InkKit and adds its own shell.
let package = Package(
    name: "Tetodoro",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "TetodoroCore", targets: ["TetodoroCore"]),
        .library(name: "InkKit", targets: ["InkKit"]),
        .executable(name: "Tetodoro", targets: ["TetodoroApp"]),
    ],
    targets: [
        .target(name: "TetodoroCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "InkKit"),
        .executableTarget(name: "TetodoroApp", dependencies: ["TetodoroCore", "InkKit"]),
        // Renders Support/AppIcon.icns from the InkKit drill; see scripts/make-icon.sh.
        .executableTarget(name: "IconMaker", dependencies: ["InkKit"]),
        .testTarget(name: "TetodoroCoreTests", dependencies: ["TetodoroCore"]),
    ]
)
