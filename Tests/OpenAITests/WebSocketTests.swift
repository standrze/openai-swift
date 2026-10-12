import Foundation
import XCTest

@testable import OpenAI

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class WebSocketTests: XCTestCase {
    func testClientAndServiceConnectionsPreservePrefixAuthenticationAndQuery() async throws {
        let socket = FakeWebSocketConnection()
        let transport = FakeWebSocketTransport(connection: socket)
        let client = OpenAIClient(
            configuration: ClientConfiguration(
                apiKey: "socket-key", baseURL: URL(string: "https://example.test/proxy/v1")!, organization: "org-socket"
            ))

        let responses = try await client.responses.connect(
            options: RequestOptions(headers: ["X-Trace": "trace"], query: ["vendor": "a/b"]), transport: transport
        )
        let realtime = try await client.realtime.connect(model: "model with space", transport: transport)
        await responses.close()
        await realtime.close()

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.scheme, "wss")
        XCTAssertEqual(requests[0].url?.path, "/proxy/v1/responses")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer socket-key")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "OpenAI-Organization"), "org-socket")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Trace"), "trace")
        let query = URLComponents(url: try XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "model" })?.value, "model with space")
    }

    func testResponsesCreateUsesTopLevelParametersAndImplicitStreaming() async throws {
        let socket = FakeWebSocketConnection()
        let connection = OpenAIJSONConnection(connection: socket)
        var request = ResponseRequest(model: "test-model", input: "Hello")
        request.previousResponseID = "resp-before"

        try await connection.createResponse(
            request, extraBody: ["stream": true, "background": false, "stream_id": "main"])

        let sent = await socket.sent
        let payload = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(sent.first).bytes)
        XCTAssertEqual(payload["type"], "response.create")
        XCTAssertEqual(payload["model"], "test-model")
        XCTAssertEqual(payload["input"], "Hello")
        XCTAssertEqual(payload["previous_response_id"], "resp-before")
        XCTAssertEqual(payload["stream_id"], "main")
        XCTAssertNil(payload["response"])
        XCTAssertNil(payload["stream"])
        XCTAssertNil(payload["background"])

        request.background = true
        do {
            try await connection.createResponse(request)
            XCTFail("Background responses are unsupported on WebSocket")
        } catch OpenAIClientError.invalidConfiguration {}
        let count = await socket.sent.count
        XCTAssertEqual(count, 1)
    }

    func testReceivesTextAndBinaryJSONWithoutDroppingProviderFields() async throws {
        let socket = FakeWebSocketConnection(messages: [
            .text(#"{"type":"session.created","vendor":{"enabled":true}}"#),
            .data(
                Data(#"{"type":"response.output_text.delta","delta":"hello","output_index":0,"content_index":0}"#.utf8)),
        ])
        let connection = OpenAIJSONConnection(connection: socket)

        let raw = try await connection.receive()
        let event = try await connection.receiveResponseEvent()

        XCTAssertEqual(raw["vendor"]?["enabled"], true)
        XCTAssertEqual(event.type, "response.output_text.delta")
        XCTAssertEqual(event.textDelta, "hello")
    }

    func testResponsesReceiversRejectEventsWithoutType() async throws {
        for raw in [#"{}"#, #"{"type":""}"#] {
            for final in [false, true] {
                let socket = FakeWebSocketConnection(messages: [.text(raw)])
                let connection = OpenAIJSONConnection(connection: socket)
                do {
                    if final {
                        _ = try await connection.finalResponse()
                    } else {
                        _ = try await connection.receiveResponseEvent()
                    }
                    XCTFail("Missing event type must fail before reading another message")
                } catch OpenAIClientError.invalidStream(let message) {
                    XCTAssertTrue(message.contains("missing type"))
                }
            }
        }
    }

    func testFinalResponseReturnsTerminalServerPayloadAndPreservesProtocolErrors() async throws {
        let socket = FakeWebSocketConnection(messages: [
            .text(#"{"type":"response.created","response":{"id":"resp-1","output":[]}}"#),
            .text(#"{"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"draft"}"#),
            .text(
                #"{"type":"response.completed","response":{"id":"resp-1","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"server final"}]}],"vendor":"retained"}}"#
            ),
        ])
        let result = try await OpenAIJSONConnection(connection: socket).finalResponse()
        XCTAssertEqual(result.outputText, "server final")
        XCTAssertEqual(result.rawValue["vendor"], "retained")

        for status in ["failed", "incomplete"] {
            let raw: JSONValue = [
                "type": .string("response." + status), "response": ["id": "r", "status": .string(status)],
            ]
            let message = String(decoding: try JSONEncoder().encode(raw), as: UTF8.self)
            let connection = OpenAIJSONConnection(connection: FakeWebSocketConnection(messages: [.text(message)]))
            let result = try await connection.finalResponse()
            XCTAssertEqual(result.status, status)
        }
        for type in ["error"] {
            let raw: JSONValue = ["type": .string(type), "error": ["code": "fixture", "message": "failed"]]
            let message = String(decoding: try JSONEncoder().encode(raw), as: UTF8.self)
            let failed = OpenAIJSONConnection(connection: FakeWebSocketConnection(messages: [.text(message)]))
            do {
                let _ = try await failed.finalResponse()
                XCTFail("Expected terminal failure for \(type)")
            } catch OpenAIWebSocketError.responseTerminated(let event) {
                XCTAssertEqual(event.type, type)
                XCTAssertEqual(event.rawValue, raw)
            }
        }
    }

    func testFinalResponseRejectsEarlyCloseAndMixedResponseIDs() async throws {
        for messages: [WebSocketMessage] in [
            [.text(#"{"type":"response.created","response":{"id":"resp-1"}}"#)],
            [
                .text(#"{"type":"response.created","response":{"id":"resp-1"}}"#),
                .text(#"{"type":"response.completed","response":{"id":"resp-2","output":[]}}"#),
            ],
            [.text(#"{"type":"response.completed"}"#)],
        ] {
            let connection = OpenAIJSONConnection(connection: FakeWebSocketConnection(messages: messages))
            do {
                let _ = try await connection.finalResponse()
                XCTFail("A completed response must come from a matching terminal server payload")
            } catch OpenAIClientError.invalidStream {}
        }
    }

    func testJSONMessageLimitsApplyToInjectedTransportsAndDoNotReplay() async throws {
        let socket = FakeWebSocketConnection(messages: [.text(#"{"value":"too long"}"#)])
        let connection = OpenAIJSONConnection(connection: socket, maxMessageBytes: 8)

        do {
            try await connection.send(JSONValue.string("too long"))
            XCTFail("Expected outgoing size limit")
        } catch OpenAIWebSocketError.messageTooLarge(let limit) {
            XCTAssertEqual(limit, 8)
        }
        do {
            let _ = try await connection.receive()
            XCTFail("Expected incoming size limit")
        } catch OpenAIWebSocketError.messageTooLarge {}

        let sent = await socket.sent
        let closed = await socket.closeCodes
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(closed, [.messageTooBig])
    }

    func testConcurrentReceiversAreRejectedUntilTheFirstCompletes() async throws {
        let socket = FakeWebSocketConnection(blockWhenEmpty: true)
        let connection = OpenAIJSONConnection(connection: socket)
        let first = Task { try await connection.receive() }
        await socket.waitForPendingReceive()
        let isPending = await socket.hasPendingReceive
        XCTAssertTrue(isPending)

        do {
            let _ = try await connection.receive()
            XCTFail("Expected concurrent receiver error")
        } catch OpenAIWebSocketError.concurrentReceive {}

        await socket.deliver(.text(#"{"value":"first"}"#))
        let received = try await first.value
        XCTAssertEqual(received["value"], "first")
        await connection.close()
    }

    func testInvalidHandshakeConfigurationFailsBeforeTransportUse() async throws {
        let transport = FakeWebSocketTransport(connection: FakeWebSocketConnection())
        let client = OpenAIClient(configuration: .ollama())
        do {
            let _ = try await client.connect(
                path: "responses", webSocketOptions: .init(maxMessageBytes: -1), transport: transport)
            XCTFail("Expected invalid message limit")
        } catch OpenAIClientError.invalidConfiguration {}
        do {
            let _ = try await client.connect(
                path: "responses", options: RequestOptions(extraBody: ["unexpected": true]), transport: transport)
            XCTFail("A handshake cannot contain JSON body extensions")
        } catch OpenAIClientError.invalidConfiguration {}
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }
}

private actor FakeWebSocketTransport: OpenAIWebSocketTransport {
    let connection: any OpenAIWebSocketConnection
    private(set) var requests: [URLRequest] = []

    init(connection: any OpenAIWebSocketConnection) { self.connection = connection }

    func connect(_ request: URLRequest, options: WebSocketOptions) async throws -> any OpenAIWebSocketConnection {
        requests.append(request)
        return connection
    }
}

private actor FakeWebSocketConnection: OpenAIWebSocketConnection {
    private var messages: [WebSocketMessage]
    private let blockWhenEmpty: Bool
    private var pending: CheckedContinuation<WebSocketMessage, any Error>?
    private var pendingObserver: CheckedContinuation<Void, Never>?
    private(set) var sent: [WebSocketMessage] = []
    private(set) var closeCodes: [WebSocketCloseCode] = []
    var hasPendingReceive: Bool { pending != nil }

    init(messages: [WebSocketMessage] = [], blockWhenEmpty: Bool = false) {
        self.messages = messages
        self.blockWhenEmpty = blockWhenEmpty
    }

    func send(_ message: WebSocketMessage) async throws { sent.append(message) }

    func receive() async throws -> WebSocketMessage {
        if !messages.isEmpty { return messages.removeFirst() }
        guard blockWhenEmpty else { throw OpenAIWebSocketError.closed(code: 1000, reason: nil) }
        return try await withCheckedThrowingContinuation {
            pending = $0
            pendingObserver?.resume()
            pendingObserver = nil
        }
    }

    func waitForPendingReceive() async {
        if pending != nil { return }
        await withCheckedContinuation { pendingObserver = $0 }
    }

    func deliver(_ message: WebSocketMessage) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: message)
    }

    func close(code: WebSocketCloseCode, reason: Data?) async {
        closeCodes.append(code)
        let continuation = pending
        pending = nil
        continuation?.resume(throwing: OpenAIWebSocketError.closed(code: code.rawValue, reason: reason))
    }
}
