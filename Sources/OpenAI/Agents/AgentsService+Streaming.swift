import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

extension AgentsService {
    /// Subscribes before submitting input to an idle session. Use one input writer per session while this runs.
    public func stream(
        sessionID: String, input: JSONValue, toolHandlers: [String: AgentToolHandler] = [:],
        idempotencyKey: String? = nil, onToolError: (@Sendable (AgentToolError) -> Void)? = nil,
        options: RequestOptions = .init()
    ) async throws -> AgentSessionStream {
        let messages: [JSONValue]
        if let text = input.stringValue, !text.isEmpty {
            messages = [["content": [["type": "input_text", "text": .string(text)]]]]
        } else if let list = input.arrayValue, !list.isEmpty, list.allSatisfy({ $0.objectValue != nil }) {
            messages = list
        } else {
            throw OpenAIClientError.invalidConfiguration("Agent input must be nonempty text or messages")
        }
        guard try await sessions.retrieve(sessionID, options: options)["status"] == "idle" else {
            throw OpenAIClientError.invalidConfiguration("Agent stream requires an idle session")
        }
        let events = try await streamEvents(sessionID, options: options)
        var submission = options
        var keyProbe = URLRequest(url: sessions.client.configuration.baseURL)
        for (name, value) in sessions.client.configuration.headers {
            keyProbe.setValue(value, forHTTPHeaderField: name)
        }
        if let idempotencyKey { keyProbe.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        for (name, value) in options.headers { keyProbe.setValue(value, forHTTPHeaderField: name) }
        for mutation in options.headerMutations { try mutation.apply(to: &keyProbe) }
        let supplied = keyProbe.value(forHTTPHeaderField: "Idempotency-Key") ?? ""
        submission.headerMutations.append(.set("Idempotency-Key", supplied.isEmpty ? UUID().uuidString : supplied))
        do {
            try await submitEvent(
                sessionID, body: ["events": [["type": "agent.session.input.message", "input": .array(messages)]]],
                options: submission)
            return AgentSessionStream(
                stream: events, service: self, sessionID: sessionID, options: options,
                handlers: toolHandlers, onToolError: onToolError)
        } catch {
            events.cancel()
            throw error
        }
    }

    /// Creates a session and observes its first turn. Only registered local function handlers execute during iteration.
    public func createSessionStream(
        _ body: JSONValue, toolHandlers: [String: AgentToolHandler] = [:],
        onToolError: (@Sendable (AgentToolError) -> Void)? = nil, options: RequestOptions = .init()
    ) async throws -> AgentSessionStream {
        var scoped = sessions.mergedOptions(options)
        scoped.extraBody["stream"] = true
        let events: OpenAIStream<JSONValue> = try await sessions.client.stream(
            path: sessions.path, body: body, options: scoped)
        return AgentSessionStream(
            stream: events, service: self, options: options, handlers: toolHandlers,
            onToolError: onToolError, allowEOF: true)
    }
}
