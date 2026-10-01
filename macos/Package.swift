// swift-tools-version: 5.9
import PackageDescription

// GhostHand for macOS — a native Swift port of the Windows C# / .NET 8 application.
//
// Layer map (mirrors the Windows solution):
//   GhostHand.Core      -> GhostHandCore      (platform-independent logic, no AppKit)
//   GhostHand.Platform  -> GhostHandPlatform  (Accessibility / CGEvent / Keychain / Vision)
//   GhostHand.Cli       -> GhostHandCLI       (binary: `ghosthand`)
//   GhostHand.App       -> GhostHandApp       (binary: `GhostHandApp`, wrapped into a .app bundle)
let package = Package(
    name: "GhostHand",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GhostHandCore", targets: ["GhostHandCore"]),
        .library(name: "GhostHandPlatform", targets: ["GhostHandPlatform"]),
        .executable(name: "ghosthand", targets: ["GhostHandCLI"]),
    ],
    targets: [
        .target(
            name: "GhostHandCore",
            path: "Sources/GhostHandCore"
        ),
        .target(
            name: "GhostHandPlatform",
            dependencies: ["GhostHandCore"],
            path: "Sources/GhostHandPlatform"
        ),
        .executableTarget(
            name: "GhostHandCLI",
            dependencies: ["GhostHandCore", "GhostHandPlatform"],
            path: "Sources/GhostHandCLI"
        ),
        .testTarget(
            name: "GhostHandCoreTests",
            dependencies: ["GhostHandCore"],
            path: "Tests/GhostHandCoreTests"
        ),
    ]
)
