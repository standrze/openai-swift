import Foundation
import OpenAI

/// A standalone consumer example; this source is deliberately outside the library target.
@main
struct OllamaExample {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let streams = arguments.contains("--stream")
        let positional = arguments.filter { $0 != "--stream" }
        let model = positional.first ?? "llama3.2"
        let prompt =
            positional.count > 1
            ? positional.dropFirst().joined(separator: " ")
            : "Explain Swift structured concurrency."
        let address = ProcessInfo.processInfo.environment["OLLAMA_BASE_URL"] ?? "http://localhost:11434/v1"
        guard let baseURL = URL(string: address) else {
            throw ExampleError.invalidURL(address)
        }
        let client = OpenAIClient(configuration: .ollama(baseURL: baseURL))
        let request = ChatCompletionRequest(
            model: model,
            messages: [.system("Answer in one concise paragraph."), .user(prompt)],
            streamOptions: streams ? .init(includeUsage: true) : nil
        )

        if streams {
            let stream = try await client.chat.completions.stream(request)
            defer { stream.cancel() }
            var accumulator = ChatCompletionAccumulator()
            for try await chunk in stream {
                accumulator.add(chunk)
                for choice in chunk.choices {
                    if let text = choice.delta.content { print(text, terminator: "") }
                }
            }
            print()
            if let tokens = accumulator.completion?.usage?.totalTokens {
                print("Total tokens: \(tokens)")
            }
        } else {
            let response = try await client.chat.completions.create(request)
            print(response.choices.first?.message.text ?? "")
        }
    }
}

private enum ExampleError: Error, LocalizedError {
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value): return "Invalid OLLAMA_BASE_URL: \(value)"
        }
    }
}
