// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PasskeyManager",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "PasskeyManager",
            targets: ["PasskeyManager"]
        ),
    ],
    targets: [
        .target(
            name: "PasskeyManager",
            dependencies: [],
            path: "Sources/PasskeyManager"
        ),
        .testTarget(
            name: "PasskeyManagerTests",
            dependencies: ["PasskeyManager"],
            path: "Tests/PasskeyManagerTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
