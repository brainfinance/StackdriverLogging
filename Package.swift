// swift-tools-version:5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "StackdriverLogging",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "StackdriverLogging", targets: ["StackdriverLogging"]),
    ],
    dependencies: [
        // Swift logging API
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),

        // Used for threadPool
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.64.0"),

        // Used for fileIO
        .package(url: "https://github.com/apple/swift-system.git", from: "1.2.1"),
    ],
    targets: [
        .target(
            name: "StackdriverLogging",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "SystemPackage", package: "swift-system"),
            ]
        ),
        .testTarget(name: "StackdriverLoggingTests", dependencies: ["StackdriverLogging"]),
    ]
)
