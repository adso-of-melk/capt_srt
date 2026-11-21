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
        // The core: titles, projects, subtitle formats, QC rules, line breaking, timing rules,
        // file matching. No windows and no AppKit, so a later iOS (or other) app can share it.
        // For now the app reaches it with `@testable import`, so its code needs no `public`
        // marks yet; hence `-enable-testing` in every build, release too.
        .target(
            name: "TitlesCore",
            path: "Sources/TitlesCore",
            swiftSettings: [.unsafeFlags(["-enable-testing"])]
        ),
        // The Mac app: windows, playback, audio, input, spelling.
        .executableTarget(
            name: "Titles",
            dependencies: ["CHunspell", "TitlesCore"],
            path: "Sources/Titles"
        ),
        // Run with `swift test`.
        .testTarget(
            name: "TitlesTests",
            dependencies: ["Titles", "TitlesCore"],
            path: "Tests/TitlesTests"
        )
    ]
)
