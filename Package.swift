// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "netglide",
    products: [
        .library(
            name: "NetGlide",
            targets: ["NetGlide"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/async-http-client.git", "1.34.0" ..< "1.36.2"),
    ],
    targets: [
        .target(
            name: "NetGlide",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ],
            path: "Sources/NetGlide"
        ),
        .testTarget(
            name: "NetGlideTests",
            dependencies: ["NetGlide"],
            path: "Tests/NetGlideTests"
        ),
    ]
)
