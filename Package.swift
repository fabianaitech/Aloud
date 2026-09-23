// swift-tools-version:6.0
// Package.swift — SPM executable manifest for Aloud, the menubar front-end to the
// local speech engine (~/.aloud). Zero dependencies: AppKit and
// ServiceManagement only. Language mode pinned to v5 for the same reason as Claude
// Island — this is an app, not a library, and Swift 6 strict-concurrency warnings
// aren't worth the build time here.
import PackageDescription

let package = Package(
    name: "AloudBar",
    platforms: [.macOS(.v13)],   // SMAppService (Launch at Login) is macOS 13+.
    products: [
        .executable(name: "AloudBar", targets: ["AloudBar"]),
        // The Apple engine's synthesis helper: Siri voices, and no per-sentence
        // `say` start-up. Installed to ~/.aloud; the daemon falls back to `say`
        // without it.
        .executable(name: "aloud-apple", targets: ["AloudApple"]),
    ],
    targets: [
        .executableTarget(
            name: "AloudBar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AloudApple",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
