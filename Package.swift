// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LCLWebSocket",
    platforms: [
        .macOS(.v10_15), .iOS(.v13), .watchOS(.v4), .tvOS(.v13), .visionOS(.v1),
    ],
    products: [
        .library(
            name: "LCLWebSocket",
            targets: ["LCLWebSocket"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.23.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.28.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.2"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
        .package(url: "https://github.com/adam-fowler/compress-nio.git", from: "1.4.0"),
    ],
    targets: [
        .target(
            name: "LCLWebSocket",
            dependencies: [
                "CLCLWebSocketZlib",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(
                    name: "NIOTransportServices",
                    package: "swift-nio-transport-services",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS, .macCatalyst])
                ),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "CompressNIO", package: "compress-nio"),
            ]
        ),
        .target(
            name: "CLCLWebSocketZlib",
            linkerSettings: [
                .linkedLibrary("z")
            ]
        ),
        .testTarget(
            name: "LCLWebSocketTests",
            dependencies: ["LCLWebSocket"]
        ),
        .executableTarget(
            name: "AutobahnClient",
            dependencies: ["LCLWebSocket"]
        ),
        .executableTarget(
            name: "AutobahnServer",
            dependencies: ["LCLWebSocket"]
        ),
        .executableTarget(name: "Client", dependencies: ["LCLWebSocket"]),
        .executableTarget(name: "Server", dependencies: ["LCLWebSocket"]),
    ]
)
