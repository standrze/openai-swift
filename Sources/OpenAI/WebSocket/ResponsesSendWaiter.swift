import Foundation

/// Cancelling an admitted write while it waits for the preceding write does not cancel that preceding write.
final class ResponsesSendWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, any Error>?
    private var continuation: CheckedContinuation<Void, any Error>?

    static func wait(for previous: Task<Void, any Error>) async throws {
        let state = ResponsesSendWaiter()
        let observer = Task {
            _ = await previous.result
            state.finish(.success(()))
        }
        defer { observer.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { state.attach($0) }
        } onCancel: {
            state.finish(.failure(CancellationError()))
        }
    }
    private func attach(_ continuation: CheckedContinuation<Void, any Error>) {
        let completed = lock.withLock { () -> Result<Void, any Error>? in
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let completed { continuation.resume(with: completed) }
    }
    private func finish(_ result: Result<Void, any Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(with: result)
    }
}
