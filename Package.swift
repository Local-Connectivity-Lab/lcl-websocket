// swift-tools-version: 5.10
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
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.76.1"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.23.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.28.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.24.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.2"),
    ],
    targets: [
        .target(
            name: "LCLWebSocket",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(
                    name: "NIOTransportServices",
                    package: "swift-nio-transport-services",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS, .macCatalyst])
                ),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "LCLWebSocketTests",
            dependencies: ["LCLWebSocket"]
        ),
        .executableTarget(name: "Client", dependencies: ["LCLWebSocket"]),
        .executableTarget(name: "Server", dependencies: ["LCLWebSocket"]),
    ]
)
