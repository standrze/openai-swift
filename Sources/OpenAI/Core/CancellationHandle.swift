import Foundation

/// Makes cancellation idempotent even when completion and task cancellation race.
final class CancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    init(_ action: @escaping @Sendable () -> Void) { self.action = action }

    func cancel() {
        let action = lock.withLock {
            let result = self.action
            self.action = nil
            return result
        }
        action?()
    }
}
