// swift-tools-version: 5.9
// Titles — a focused subtitle (SRT) editor for macOS.
// Open this file in Xcode (File ▸ Open… ▸ Package.swift) and press Run,
// or run `swift run` from Terminal.

import PackageDescription

let package = Package(
    name: "Titles",
    platforms: [.macOS(.v14)],
    targets: [
        // Hunspell, the spell-checking engine, for languages macOS doesn't check (MPL 1.1).
        .target(
            name: "CHunspell",
            path: "Sources/CHunspell",
            exclude: ["README.md", "COPYING.MPL", "license.hunspell", "license.myspell"],
            sources: ["src"],
            publicHeadersPath: "include",
            cxxSettings: [
                .define("HUNSPELL_STATIC"),
                .headerSearchPath("include"),
                .unsafeFlags(["-w"])
            ]
        ),
        .executableTarget(
            name: "Titles",
            dependencies: ["CHunspell"],
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
