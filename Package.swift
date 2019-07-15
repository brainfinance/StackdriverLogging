// swift-tools-version:5.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "StackdriverLogger",
    products: [
        .library(name: "StackdriverLogger", targets: ["StackdriverLogger"]),
    ],
    dependencies: [
        // Swift logging API
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "StackdriverLogger", dependencies: ["Logging"]),
        .testTarget(name: "StackdriverLoggerTests", dependencies: ["StackdriverLogger"]),
    ]
)
