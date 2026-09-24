// swift-tools-version: 6.0
// Tebo — native macOS cleaner (SwiftUI shell + Rust engine).
// Open in Xcode: open Package.swift  (macOS 14+, Swift 6)

import PackageDescription

let package = Package(
    name: "Tebo",
    platforms: [
        .macOS(.v14) // Needed for @Observable + modern SwiftUI
    ],
    products: [
        .executable(name: "Tebo", targets: ["Tebo"])
    ],
    targets: [
        .executableTarget(
            name: "Tebo",
            path: "Sources/Tebo",
            resources: [
                .copy("../../Resources")
            ]
        ),
        .testTarget(
            name: "TeboTests",
            dependencies: ["Tebo"],
            path: "Tests/TeboTests"
        )
    ]
)
