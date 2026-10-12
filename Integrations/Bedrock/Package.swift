// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenAIBedrock",
    platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9)],
    products: [.library(name: "OpenAIBedrock", targets: ["OpenAIBedrock"])],
    dependencies: [
        .package(name: "OpenAI", path: "../.."),
        .package(url: "https://github.com/awslabs/aws-sdk-swift", exact: "1.8.7"),
        .package(url: "https://github.com/smithy-lang/smithy-swift", exact: "0.256.0"),
    ],
    targets: [
        .target(
            name: "OpenAIBedrock",
            dependencies: [
                .product(name: "OpenAI", package: "OpenAI"),
                .product(name: "AWSClientRuntime", package: "aws-sdk-swift"),
                .product(name: "AWSSDKCommon", package: "aws-sdk-swift"),
                .product(name: "AWSSDKHTTPAuth", package: "aws-sdk-swift"),
                .product(name: "AWSSDKIdentity", package: "aws-sdk-swift"),
                .product(name: "ClientRuntime", package: "smithy-swift"),
                .product(name: "Smithy", package: "smithy-swift"),
                .product(name: "SmithyHTTPAPI", package: "smithy-swift"),
                .product(name: "SmithyHTTPAuth", package: "smithy-swift"),
                .product(name: "SmithyHTTPAuthAPI", package: "smithy-swift"),
                .product(name: "SmithyIdentity", package: "smithy-swift"),
            ]),
        .testTarget(name: "OpenAIBedrockTests", dependencies: ["OpenAIBedrock"]),
    ]
)
