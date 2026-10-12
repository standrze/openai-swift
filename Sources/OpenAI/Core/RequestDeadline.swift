import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Cancellation-aware operation deadlines, including authentication and response-body consumption.
public enum RequestDeadline {
    @TaskLocal public static var current: Date?
    /// Foundation uses a finite timeout representation; zero disables SDK deadlines.
    public static let unlimitedInterval: TimeInterval = TimeInterval(Int32.max)

    public static func end(timeout: TimeInterval, deadline: Date?, now: Date = Date()) throws -> Date? {
        guard timeout.isFinite, timeout >= 0, deadline?.timeIntervalSince1970.isFinite ?? true else {
            throw OpenAIClientError.invalidConfiguration("Invalid request deadline")
        }
        let attempt = timeout > 0 ? now.addingTimeInterval(timeout) : nil
        if let attempt, let deadline { return min(attempt, deadline) }
        return attempt ?? deadline
    }

    /// Cancellation propagates to the operation. Custom transports and token providers must cooperate with cancellation.
    public static func run<Value: Sendable>(
        until deadline: Date?, operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard let deadline else { return try await operation() }
        let seconds = deadline.timeIntervalSinceNow
        guard seconds > 0 else { throw URLError(.timedOut) }
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await $current.withValue(deadline, operation: operation) }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    /// Applies the same attempt deadline after streaming headers have arrived.
    public static func stream(_ response: HTTPStreamResponse, until deadline: Date?) -> HTTPStreamResponse {
        guard let deadline else { return response }
        let pair = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let task = Task {
            do {
                try await run(until: deadline) {
                    for try await chunk in response.body {
                        try Task.checkCancellation()
                        if case .dropped = pair.continuation.yield(chunk) { throw OpenAIClientError.streamOverflow }
                    }
                }
                pair.continuation.finish()
            } catch { pair.continuation.finish(throwing: error) }
            response.cancel()
        }
        pair.continuation.onTermination = { @Sendable _ in
            task.cancel()
            response.cancel()
        }
        return HTTPStreamResponse(
            statusCode: response.statusCode, headers: response.headers, body: pair.stream,
            cancel: {
                task.cancel()
                response.cancel()
            })
    }
}
