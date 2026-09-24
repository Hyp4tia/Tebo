// swift-tools-version: 6.0
// SuperClean — native macOS cleaner (SwiftUI shell + Rust engine).
// Open in Xcode: open Package.swift  (macOS 14+, Swift 6)

import PackageDescription

let package = Package(
    name: "SuperClean",
    platforms: [
        .macOS(.v14) // Needed for @Observable + modern SwiftUI
    ],
    products: [
        .executable(name: "SuperClean", targets: ["SuperClean"])
    ],
    targets: [
        .executableTarget(
            name: "SuperClean",
            path: "Sources/SuperClean",
            resources: [
                .copy("../../Resources")
            ]
        ),
        .testTarget(
            name: "SuperCleanTests",
            dependencies: ["SuperClean"],
            path: "Tests/SuperCleanTests"
        )
    ]
)
