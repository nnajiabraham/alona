// swift-tools-version: 6.0
// Package.swift for SPM-based testing (swift test)
// This allows CI to run tests without launching the app

import PackageDescription

let package = Package(
    name: "Alona",
    platforms: [
        .macOS("14.2")  // Required for AudioHardwareDestroyProcessTap etc.
    ],
    products: [
        // Library product for testing
        .library(name: "AlonaCore", targets: ["AlonaCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", branch: "master"),
        .package(url: "https://github.com/krzysztofzablocki/Inject.git", from: "1.5.0")
    ],
    targets: [
        // Core library containing testable code
        .target(
            name: "AlonaCore",
            dependencies: [
                "SwiftWhisper",
                "Inject"
            ],
            path: "Alona",
            exclude: [
                "main.swift",           // App entry point
                "AlonaApp.swift",       // SwiftUI App
                "AppDelegate.swift",    // AppKit delegate
                "Resources",            // Bundle resources
                "Info.plist"
            ],
            sources: [
                "Models",
                "Services",
                "Views",
                "Utilities",
                "DesignSystem.swift"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // Test target
        .testTarget(
            name: "AlonaTests",
            dependencies: ["AlonaCore"],
            path: "AlonaTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
