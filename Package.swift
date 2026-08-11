// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OpenAIUsageBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenAIUsageBar", targets: ["OpenAIUsageBar"])
    ],
    targets: [
        .executableTarget(
            name: "OpenAIUsageBar",
            path: "Sources/OpenAIUsageBar"
        )
    ]
)
