// swift-tools-version: 6.2
import PackageDescription

#if os(Linux)
    let socketPackages: [Package.Dependency] = [
        .package(url: "https://github.com/vapor/websocket-kit.git", exact: "2.16.2"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.103.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.36.1"),
    ]
    let socketProducts: [Target.Dependency] = [
        .product(name: "WebSocketKit", package: "websocket-kit"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOWebSocket", package: "swift-nio"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
    ]
#else
    let socketPackages: [Package.Dependency] = []
    let socketProducts: [Target.Dependency] = []
#endif

let package = Package(
    name: "OpenAI",
    platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9)],
    products: [
        .library(name: "OpenAI", targets: ["OpenAI"]),
        .library(name: "OpenAIAPI", targets: ["OpenAIAPI"]),
    ],
    dependencies: [
        // Maintained cross-platform cryptography; no private SHA/HMAC implementation.
        .package(url: "https://github.com/apple/swift-crypto", exact: "3.14.0"),
        // Runtime for Apple's generated, full-schema client and streaming multipart bodies.
        .package(url: "https://github.com/apple/swift-openapi-runtime", exact: "1.13.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", exact: "1.3.2"),
        .package(url: "https://github.com/apple/swift-http-types", exact: "1.7.0"),
    ] + socketPackages,
    targets: [
        .target(name: "OpenAI", dependencies: [.product(name: "Crypto", package: "swift-crypto")] + socketProducts),
        .target(
            name: "OpenAIAPI",
            dependencies: [
                "OpenAI", .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]),
        .testTarget(
            name: "OpenAIAPITests",
            dependencies: [
                "OpenAIAPI", "OpenAI", .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]),
        .testTarget(name: "OpenAITests", dependencies: ["OpenAI"], resources: [.copy("Fixtures")]),
    ]
)
