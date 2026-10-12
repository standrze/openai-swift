import Foundation

/// Pull cancellation removes only that waiter. The shared reader and queued events remain usable.
final class ResponsesEventQueue: @unchecked Sendable {
    private typealias Waiter = CheckedContinuation<QueuedResponseEvent?, any Error>
    private let lock = NSLock()
    private let limit: Int
    private var events: [QueuedResponseEvent?] = []
    private var index = 0
    private var receiver: UUID?
    private var cancelled = false
    private var waiter: Waiter?
    private var finished = false
    private var failure: (any Error)?
    init(limit: Int) { self.limit = limit }

    func yield(_ event: QueuedResponseEvent) -> Bool {
        let result = lock.withLock { () -> (Bool, Waiter?) in
            guard !finished else { return (false, nil) }
            if let waiter {
                self.waiter = nil
                return (true, waiter)
            }
            guard limit == 0 || events.count - index < limit else { return (false, nil) }
            events.append(event)
            return (true, nil)
        }
        result.1?.resume(returning: event)
        return result.0
    }

    func next() async throws -> QueuedResponseEvent? {
        try Task.checkCancellation()
        let id = UUID()
        try lock.withLock {
            guard receiver == nil else { throw OpenAIWebSocketError.concurrentReceive }
            receiver = id
            cancelled = false
        }
        defer {
            lock.withLock {
                if receiver == id {
                    receiver = nil
                    cancelled = false
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<QueuedResponseEvent?, any Error>? = lock.withLock {
                    if cancelled || Task.isCancelled { return .failure(CancellationError()) }
                    if index < events.count {
                        let event = events[index]
                        events[index] = nil
                        index += 1
                        if index == events.count {
                            events.removeAll(keepingCapacity: true)
                            index = 0
                        } else if index > 1024, index > events.count / 2 {
                            events.removeFirst(index)
                            index = 0
                        }
                        return .success(event)
                    }
                    if finished { return failure.map(Result.failure) ?? .success(nil) }
                    waiter = continuation
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let pending = self.lock.withLock { () -> Waiter? in
                guard self.receiver == id else { return nil }
                self.cancelled = true
                let pending = self.waiter
                self.waiter = nil
                return pending
            }
            pending?.resume(throwing: CancellationError())
        }
    }

    func finish(throwing error: (any Error)? = nil, discarding: Bool = false) {
        let pending = lock.withLock { () -> Waiter? in
            guard !finished else { return nil }
            finished = true
            failure = error
            if discarding {
                events.removeAll()
                index = 0
            }
            let pending = waiter
            waiter = nil
            return pending
        }
        if let error { pending?.resume(throwing: error) } else { pending?.resume(returning: nil) }
    }
}
