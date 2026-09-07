// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AIusage",
    defaultLocalization: "es",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AIusage", targets: ["AIusage"])
    ],
    targets: [
        .executableTarget(
            name: "AIusage",
            path: "Sources/AIusage",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "AIusageTests",
            dependencies: ["AIusage"],
            path: "Tests/AIusageTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
