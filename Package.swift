// swift-tools-version: 5.9
// Titles — a focused subtitle (SRT) editor for macOS.
// Open this file in Xcode (File ▸ Open… ▸ Package.swift) and press Run,
// or run `swift run` from Terminal.

import PackageDescription

let package = Package(
    name: "Titles",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Titles",
            path: "Sources/Titles"
        ),
        // Run with `swift test`.
        .testTarget(
            name: "TitlesTests",
            dependencies: ["Titles"],
            path: "Tests/TitlesTests"
        )
    ]
)
