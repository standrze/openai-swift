import Foundation

@testable import OpenAI

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct TestDocument: Codable, Sendable, Equatable {
    var value: String
}

actor RecordingTransport: OpenAITransport {
    enum SendOutcome: Sendable {
        case response(HTTPResponse)
        case failure(URLError)
    }

    enum StreamOutcome: Sendable {
        case response(HTTPStreamResponse)
        case failure(URLError)
    }

    private var sendOutcomes: [SendOutcome]
    private var streamOutcomes: [StreamOutcome]
    private(set) var requests: [URLRequest] = []

    init(send: [SendOutcome] = [], stream: [StreamOutcome] = []) {
        sendOutcomes = send
        streamOutcomes = stream
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !sendOutcomes.isEmpty else {
            throw URLError(.badServerResponse)
        }
        switch sendOutcomes.removeFirst() {
        case .response(let response):
            return response
        case .failure(let error):
            throw error
        }
    }

    func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
        requests.append(request)
        guard !streamOutcomes.isEmpty else {
            throw URLError(.badServerResponse)
        }
        switch streamOutcomes.removeFirst() {
        case .response(let response):
            return response
        case .failure(let error):
            throw error
        }
    }
}

final class CancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }

    func record() {
        lock.lock()
        defer { lock.unlock() }
        storedCount += 1
    }
}

func testConfiguration(maxRetries: Int = 0) -> ClientConfiguration {
    ClientConfiguration(
        apiKey: "test-key",
        baseURL: URL(string: "https://example.test/proxy/v1")!,
        maxRetries: maxRetries,
        initialRetryDelay: 0,
        maxRetryDelay: 0
    )
}

func jsonResponse(
    _ json: String = #"{"value":"ready"}"#,
    status: Int = 200,
    headers: [String: String] = [:]
) -> HTTPResponse {
    HTTPResponse(data: Data(json.utf8), statusCode: status, headers: headers)
}

func streamResponse(
    chunks: [Data],
    status: Int = 200,
    headers: [String: String] = ["Content-Type": "text/event-stream"],
    cancel: @escaping @Sendable () -> Void = {}
) -> HTTPStreamResponse {
    HTTPStreamResponse(
        statusCode: status,
        headers: headers,
        body: AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        },
        cancel: cancel
    )
}

func streamResponse(
    text: String,
    status: Int = 200,
    headers: [String: String] = ["Content-Type": "text/event-stream"],
    cancel: @escaping @Sendable () -> Void = {}
) -> HTTPStreamResponse {
    streamResponse(chunks: [Data(text.utf8)], status: status, headers: headers, cancel: cancel)
}
