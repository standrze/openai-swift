import Foundation
import OpenAI

/// Explicit live checks; this executable never downloads models or substitutes fixture responses.
@main
@MainActor
struct OllamaCompatibility {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let address = environment["OLLAMA_BASE_URL"] ?? "http://localhost:11434/v1"
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme), url.host != nil else {
            throw LiveFailure("Invalid OLLAMA_BASE_URL")
        }
        let model = environment["OLLAMA_MODEL"] ?? "gpt-oss:latest"
        var configuration = ClientConfiguration.ollama(baseURL: url)
        configuration.maxRetries = 0
        configuration.timeout = 120
        let suite = LiveSuite(configuration: configuration, model: model)
        await suite.runModelRetrieval()
        if environment["OLLAMA_MODELS_ONLY"] == "1" {
            await suite.runGeneratedModels()
            try suite.finish(reportPath: environment["OLLAMA_REPORT_PATH"])
            return
        }
        await suite.runInference()
        await suite.runTools()
        await suite.runGenerated()
        if let embeddingModel = environment["OLLAMA_EMBEDDING_MODEL"] {
            await suite.runEmbeddings(model: embeddingModel)
        }
        if let visionModel = environment["OLLAMA_VISION_MODEL"] {
            await suite.runVision(model: visionModel)
        }
        try suite.finish(reportPath: environment["OLLAMA_REPORT_PATH"])
    }
}

@MainActor
final class LiveSuite {
    let configuration: ClientConfiguration
    let model: String
    let client: OpenAIClient
    var serverVersion: String?
    private var checks: [Check] = []
    private let startedAt = Date()

    init(configuration: ClientConfiguration, model: String) {
        self.configuration = configuration
        self.model = model
        client = OpenAIClient(configuration: configuration)
    }

    func check(_ name: String, operation: () async throws -> String) async {
        let start = Date()
        do {
            let detail = try await operation()
            checks.append(Check(name: name, passed: true, detail: detail, seconds: Date().timeIntervalSince(start)))
            print("PASS \(name): \(detail)")
        } catch {
            let detail = String(describing: error)
            checks.append(Check(name: name, passed: false, detail: detail, seconds: Date().timeIntervalSince(start)))
            print("FAIL \(name): \(detail)")
        }
    }

    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw LiveFailure(message) }
    }

    func chatRequest(_ prompt: String) -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: model, messages: [.user(prompt)], temperature: 0, maxTokens: 256, reasoningEffort: "low")
    }

    func responseRequest(_ prompt: String) -> ResponseRequest {
        var request = ResponseRequest(model: model, input: .text(prompt))
        request.maxOutputTokens = 256
        request.reasoning = ["effort": "low"]
        return request
    }

    func finish(reportPath: String?) throws {
        if let reportPath {
            let report = Report(
                startedAt: startedAt, baseURL: configuration.baseURL.absoluteString, serverVersion: serverVersion,
                model: model, checks: checks)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        }
        let failures = checks.filter { !$0.passed }.count
        print("\(checks.count - failures)/\(checks.count) live checks passed")
        if failures > 0 { throw LiveFailure("\(failures) live compatibility checks failed") }
    }

    private struct Check: Encodable {
        let name: String
        let passed: Bool
        let detail: String
        let seconds: TimeInterval
    }

    private struct Report: Encodable {
        let startedAt: Date
        let baseURL: String
        let serverVersion: String?
        let model: String
        let checks: [Check]
    }
}

struct LiveFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
