// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "netskein",
    platforms: [
        .macOS(.v11),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
        .macCatalyst(.v13),
    ],
    products: [
        .library(
            name: "NetSkein",
            targets: ["NetSkein"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/async-http-client.git", "1.34.0" ..< "1.36.2"),
    ],
    targets: [
        .target(
            name: "NetSkein",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ],
            path: "Sources/NetSkein"
        ),
        .testTarget(
            name: "NetSkeinTests",
            dependencies: ["NetSkein"],
            path: "Tests/NetSkeinTests"
        ),
    ]
)
