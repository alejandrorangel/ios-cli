// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ios-cli",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ios", targets: ["ios"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Command definitions only; all logic lives in IOSCore so it can be tested without a device.
        .executableTarget(
            name: "ios",
            dependencies: [
                "IOSCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // Resources/Runner is the XCUITest runner project, built on the user's Mac on first use
        // (it must be signed for their devices), so it ships as source.
        .target(name: "IOSCore", resources: [.copy("Resources/Runner")]),
        .testTarget(name: "IOSCoreTests", dependencies: ["IOSCore"]),
    ]
)
