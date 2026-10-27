// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "netskein",
    platforms: [.macOS(.v12), .iOS(.v15), .tvOS(.v15), .watchOS(.v8), .macCatalyst(.v15)],
    products: [
        .library(name: "NetSkein", targets: ["NetSkein"]),
        .library(name: "NetSkeinTesting", targets: ["NetSkeinTesting"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/async-http-client.git", "1.34.0"..<"1.36.2"),
        .package(url: "https://github.com/apple/swift-log", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.26.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
    ],
    targets: [
        .target(
            name: "NetSkein",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOHTTPCompression", package: "swift-nio-extras"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            path: "Sources/NetSkein",
        ),
        .target(
            name: "NetSkeinTesting",
            dependencies: [
                "NetSkein",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Sources/NetSkeinTesting",
        ),
        .testTarget(
            name: "NetSkeinTests",
            dependencies: ["NetSkein", "NetSkeinTesting"],
            path: "Tests/NetSkeinTests",
        ),
        .testTarget(
            name: "NetSkeinTestingTests",
            dependencies: ["NetSkein", "NetSkeinTesting"],
            path: "Tests/NetSkeinTestingTests",
        ),
    ]
)
