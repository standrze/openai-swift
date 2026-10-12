// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenAIExamples",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ollama-chat", targets: ["OllamaChat"]),
        .executable(name: "ollama-compatibility", targets: ["OllamaCompatibility"]),
    ],
    dependencies: [.package(name: "OpenAI", path: "..")],
    targets: [
        .executableTarget(name: "OllamaChat", dependencies: [.product(name: "OpenAI", package: "OpenAI")]),
        .executableTarget(
            name: "OllamaCompatibility",
            dependencies: [.product(name: "OpenAI", package: "OpenAI"), .product(name: "OpenAIAPI", package: "OpenAI")]),
    ]
)
