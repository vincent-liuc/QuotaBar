// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "QuotaBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "QuotaBar", targets: ["QuotaBar"])
    ],
    targets: [
        .executableTarget(
            name: "QuotaBar",
            path: "Sources/QuotaBar"
        )
    ]
)
