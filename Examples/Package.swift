// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "netskein-examples",
    platforms: [.macOS(.v12), .iOS(.v15), .tvOS(.v15), .watchOS(.v8), .macCatalyst(.v15)],
    products: [
        .executable(name: "GetHTML", targets: ["GetHTML"]),
        .executable(name: "GetJSON", targets: ["GetJSON"]),
        .executable(name: "StreamingByteCounter", targets: ["StreamingByteCounter"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),

        // in real-world projects this would be
        // .package(url: "https://github.com/orthogonest/netskein.git", from: "0.1.0")
        .package(name: "netskein", path: "../"),
    ],
    targets: [
        .executableTarget(
            name: "GetHTML",
            dependencies: [
                .product(name: "NetSkein", package: "netskein"),
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            path: "GetHTML"
        ),
        .executableTarget(
            name: "GetJSON",
            dependencies: [
                .product(name: "NetSkein", package: "netskein"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ],
            path: "GetJSON"
        ),
        .executableTarget(
            name: "StreamingByteCounter",
            dependencies: [
                .product(name: "NetSkein", package: "netskein"),
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            path: "StreamingByteCounter"
        ),
    ]
)
