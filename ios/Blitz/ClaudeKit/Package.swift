// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ClaudeKit", targets: ["ClaudeKit"]),
    ],
    targets: [
        .target(
            name: "ClaudeKit",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "ClaudeKitTests",
            dependencies: ["ClaudeKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
