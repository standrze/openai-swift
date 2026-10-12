import Foundation

/// A single-consumer stream. Call `cancel()` when stopping iteration early.
/// Task cancellation also closes the HTTP connection; events are never silently dropped.
public struct OpenAIStream<Element: Sendable>: AsyncSequence, Sendable {
    public typealias AsyncIterator = AsyncThrowingStream<Element, any Error>.Iterator
    /// The successful SSE handshake; body bytes belong to the event stream.
    public let response: HTTPResponse?
    private let storage: AsyncThrowingStream<Element, any Error>
    private let cancellation: @Sendable () -> Void

    init(
        _ storage: AsyncThrowingStream<Element, any Error>, response: HTTPResponse? = nil,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.storage = storage
        self.response = response
        cancellation = cancel
    }

    public func makeAsyncIterator() -> AsyncIterator { storage.makeAsyncIterator() }
    public func cancel() { cancellation() }
}
