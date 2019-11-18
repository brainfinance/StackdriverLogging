// swift-tools-version:5.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "StackdriverLogging",
    platforms: [
        .macOS(.v10_14)
    ],
    products: [
        .library(name: "StackdriverLogging", targets: ["StackdriverLogging"]),
    ],
    dependencies: [
        // Swift logging API
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        
        // Used for non-blocking fileIO
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.2.0")
    ],
    targets: [
        .target(name: "StackdriverLogging", dependencies: ["NIO", "Logging"]),
        .testTarget(name: "StackdriverLoggingTests", dependencies: ["StackdriverLogging"]),
    ]
)
