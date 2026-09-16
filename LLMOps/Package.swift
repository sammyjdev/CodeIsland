// swift-tools-version: 5.9
import PackageDescription

// LLMOps: native macOS telemetry + live monitor app for Claude Code, built on
// CodeIslandCore (hook event reducer, usage scanner, JSONL tailer) from the
// parent package. Kept as its own package so `swift test` here only compiles
// LLMOps targets: this machine has CommandLineTools only (swift-testing, no
// XCTest, no Xcode.app), where the parent's XCTest suites and Sparkle cannot build.
let package = Package(
    name: "LLMOps",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LLMOps", targets: ["LLMOps"]),
        .executable(name: "LLMOpsWidgets", targets: ["LLMOpsWidgets"]),
    ],
    dependencies: [
        .package(name: "CodeIsland", path: ".."),
    ],
    targets: [
        // Pure, testable logic: profiles, transcript scanning, cost, live store.
        .target(
            name: "LLMOpsCore",
            dependencies: [
                .product(name: "CodeIslandCore", package: "CodeIsland"),
            ]
        ),
        .executableTarget(
            name: "LLMOps",
            dependencies: [
                "LLMOpsCore",
                .product(name: "CodeIslandCore", package: "CodeIsland"),
            ],
            resources: [
                .copy("Resources")
            ]
        ),
        .executableTarget(
            name: "LLMOpsWidgets",
            dependencies: ["LLMOpsCore"],
            path: "Sources/LLMOpsWidgets",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [
                .linkedFramework("WidgetKit"),
                .linkedFramework("SwiftUI"),
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
            ]
        ),
        .testTarget(
            name: "LLMOpsCoreTests",
            dependencies: ["LLMOpsCore"]
        ),
        .testTarget(
            name: "LLMOpsAppTests",
            dependencies: ["LLMOps"]
        ),
    ]
)

