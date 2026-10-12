import Foundation

/// One-consumer lane events with shared queue byte/event accounting.
public struct ResponsesLaneEvents: AsyncSequence, Sendable {
    public typealias Element = ResponseEvent
    let queue: ResponsesEventQueue
    let budget: ResponsesBufferBudget
    let laneID: UUID

    public struct AsyncIterator: AsyncIteratorProtocol {
        let queue: ResponsesEventQueue
        let budget: ResponsesBufferBudget
        let laneID: UUID
        public mutating func next() async throws -> ResponseEvent? {
            if budget.isDetached(laneID) { return nil }
            guard let value = try await queue.next() else { return nil }
            budget.consumed(laneID, bytes: value.bytes)
            return budget.isDetached(laneID) ? nil : value.event
        }
    }
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(queue: queue, budget: budget, laneID: laneID)
    }
}

struct QueuedResponseEvent: Sendable {
    let event: ResponseEvent
    let bytes: Int
}

final class ResponsesBufferBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let maxEvents: Int
    private let maxBytes: Int
    private var events = 0
    private var bytes = 0
    private var lanes: [UUID: (events: Int, bytes: Int)] = [:]
    private var detached: Set<UUID> = []

    init(maxEvents: Int, maxBytes: Int) {
        self.maxEvents = maxEvents
        self.maxBytes = maxBytes
    }

    func reserve(_ id: UUID, bytes count: Int) throws {
        try lock.withLock {
            guard maxEvents == 0 || events < maxEvents, maxBytes == 0 || count <= maxBytes - bytes,
                events < Int.max, count <= Int.max - bytes
            else { throw OpenAIClientError.streamOverflow }
            events += 1
            bytes += count
            var lane = lanes[id] ?? (0, 0)
            lane.events += 1
            lane.bytes += count
            lanes[id] = lane
        }
    }
    func consumed(_ id: UUID, bytes count: Int) {
        lock.withLock {
            guard var lane = lanes[id], lane.events > 0 else { return }
            lane.events -= 1
            lane.bytes -= count
            events -= 1
            bytes -= count
            lanes[id] = lane
        }
    }
    func detach(_ id: UUID) {
        lock.withLock {
            detached.insert(id)
            if let lane = lanes.removeValue(forKey: id) {
                events -= lane.events
                bytes -= lane.bytes
            }
        }
    }
    func isDetached(_ id: UUID) -> Bool { lock.withLock { detached.contains(id) } }
}
