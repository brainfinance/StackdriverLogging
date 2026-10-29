// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "StackdriverLogging",
    platforms: [
        .macOS("26.2")
    ],
    products: [
        .library(name: "CloudLogging", targets: ["CloudLogging"]),
        .library(name: "CloudLoggingVapor", targets: ["CloudLoggingVapor"]),
    ],
    traits: [
        .trait(name: "Vapor", description: "Builds CloudTraceMiddleware in CloudLoggingVapor, which needs Vapor 5.")
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.16.1"),
        .package(url: "https://github.com/vapor/vapor.git", from: "5.0.0-beta.4"),
        .package(url: "https://github.com/vapor/routing-kit.git", from: "5.0.0-beta"),
    ],
    targets: [
        .target(
            name: "CloudLogging",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CloudLoggingVapor",
            dependencies: [
                .target(name: "CloudLogging"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Vapor", package: "vapor", condition: .when(traits: ["Vapor"])),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CloudLoggingTests",
            dependencies: [
                .target(name: "CloudLogging"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CloudLoggingVaporTests",
            dependencies: [
                .target(name: "CloudLoggingVapor"),
                .product(name: "VaporTesting", package: "vapor", condition: .when(traits: ["Vapor"])),
                .product(name: "RoutingKit", package: "routing-kit", condition: .when(traits: ["Vapor"])),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)

var swiftSettings: [SwiftSetting] {
    [
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableExperimentalFeature("SuppressedAssociatedTypesWithDefaults"),
    ]
}
