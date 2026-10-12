import Foundation

/// Limits for one Responses WebSocket session. Lane identifiers remain reserved until reconnect.
public struct ResponsesSessionOptions: Sendable {
    public var maxLanes = 64
    public var maxPendingSends = 16
    public var maxBufferedEventsPerLane = 0
    /// Zero selects unlimited buffering, matching the Go SDK.
    public var maxBufferedEvents = 0
    public var maxBufferedBytes = 0
    /// Opt-in compatibility for providers that omit stream_id from subsequent events. Default matches Go routing.
    public var inferUntaggedResponseLanes = false
    public init() {}
}

/// A response lane has one consumer. Closing a lane does not close the shared socket.
public struct ResponsesLane: Sendable {
    public let id: String?
    public let events: ResponsesLaneEvents
    private let session: ResponsesSession
    init(id: String?, events: ResponsesLaneEvents, session: ResponsesSession) {
        self.id = id
        self.events = events
        self.session = session
    }
    public func send(_ request: ResponseRequest, extraBody: [String: JSONValue] = [:]) async throws {
        try await session.send(request, laneID: id, extraBody: extraBody)
    }
    public func close() async { await session.closeLane(id) }

    /// Consumes this lane through its next terminal response event.
    public func finalResponse() async throws -> Response {
        for try await event in events {
            switch event.type {
            case "response.completed", "response.failed", "response.incomplete":
                guard let response = event.response else {
                    throw OpenAIClientError.invalidStream("Completed event is missing its response")
                }
                return response
            case "error":
                throw OpenAIWebSocketError.responseTerminated(event)
            default: continue
            }
        }
        throw OpenAIClientError.invalidStream("Lane closed before a terminal response")
    }
}

/// Conservatively reports whether a failed send could have reached the server. Requests are never replayed.
public struct WebSocketDeliveryError: Error, Sendable {
    public let mayHaveBeenSent: Bool
    public let message: String
}

/// One physical reader routes tagged events to lanes and untagged response lifecycles in send order.
/// Reconnect ends all current lane streams. Recovery may restore application state but never replays requests.
public actor ResponsesSession {
    private struct Lane {
        let events: ResponsesLaneEvents
        let id: UUID
        let queue: ResponsesEventQueue
    }
    private var budget: ResponsesBufferBudget
    private let options: ResponsesSessionOptions
    private let connector: @Sendable () async throws -> OpenAIJSONConnection
    private var connection: OpenAIJSONConnection
    private var reader: Task<Void, Never>?
    private var generation = UUID()
    private var lanes: [String: Lane] = [:]
    private var usedIDs: Set<String> = []
    private var responseLanes: [String: String] = [:]
    private struct PendingTurn {
        let id: UUID
        let key: String
    }
    private var pending: [PendingTurn] = []
    private var sendTail: Task<Void, any Error>?
    private var pendingSends = 0
    private var closed = false
    private var reconnecting = false
    private var recoveryTask: Task<Void, any Error>?

    private init(
        connection: OpenAIJSONConnection, options: ResponsesSessionOptions,
        connector: @escaping @Sendable () async throws -> OpenAIJSONConnection
    ) {
        self.budget = ResponsesBufferBudget(maxEvents: options.maxBufferedEvents, maxBytes: options.maxBufferedBytes)
        self.connection = connection
        self.options = options
        self.connector = connector
    }

    deinit {
        reader?.cancel()
        sendTail?.cancel()
        recoveryTask?.cancel()
        let connection = connection
        Task { await connection.close() }
    }

    public static func open(
        options: ResponsesSessionOptions = .init(),
        connector: @escaping @Sendable () async throws -> OpenAIJSONConnection
    ) async throws -> ResponsesSession {
        var options = options
        if options.maxLanes == 0 { options.maxLanes = 64 }
        if options.maxPendingSends == 0 { options.maxPendingSends = 16 }
        guard options.maxLanes > 0, options.maxPendingSends > 0, options.maxBufferedEventsPerLane >= 0,
            options.maxBufferedEvents >= 0, options.maxBufferedBytes >= 0
        else {
            throw OpenAIClientError.invalidConfiguration("WebSocket session limits must be positive")
        }
        let session = ResponsesSession(connection: try await connector(), options: options, connector: connector)
        _ = try await session.lane()
        await session.startReader()
        return session
    }

    /// Reserves a stream_id, or returns the shared default lane when id is nil.
    public func lane(id: String? = nil) throws -> ResponsesLane {
        guard !closed, !reconnecting else { throw OpenAIClientError.invalidStream("WebSocket session is closed") }
        let key = id ?? ""
        if let existing = lanes[key] {
            guard id == nil else { throw OpenAIClientError.invalidConfiguration("Lane is already attached") }
            return ResponsesLane(id: id, events: existing.events, session: self)
        }
        if let id {
            guard (1...256).contains(id.utf8.count),
                id.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                        || [45, 46, 95].contains($0)
                }), !usedIDs.contains(id), usedIDs.count < options.maxLanes
            else {
                throw OpenAIClientError.invalidConfiguration("Invalid, reused, or excess WebSocket lane identifier")
            }
            usedIDs.insert(id)
        }
        let idToken = UUID()
        let queue = ResponsesEventQueue(limit: options.maxBufferedEventsPerLane)
        let events = ResponsesLaneEvents(queue: queue, budget: budget, laneID: idToken)
        lanes[key] = Lane(events: events, id: idToken, queue: queue)
        return ResponsesLane(id: id, events: events, session: self)
    }

    public func send(
        _ request: ResponseRequest, laneID: String? = nil,
        extraBody: [String: JSONValue] = [:]
    ) async throws {
        try Task.checkCancellation()
        guard !closed, !reconnecting, lanes[laneID ?? ""] != nil else {
            throw WebSocketDeliveryError(mayHaveBeenSent: false, message: "Lane is unavailable")
        }
        guard pendingSends < options.maxPendingSends else {
            throw WebSocketDeliveryError(mayHaveBeenSent: false, message: "Pending send limit exceeded")
        }
        guard extraBody["stream_id"] == nil else {
            throw WebSocketDeliveryError(mayHaveBeenSent: false, message: "The session owns stream_id routing")
        }
        // Validate serialization before reserving FIFO routing state.
        var projected = try JSONValue.encode(request).objectValue ?? [:]
        projected.merge(extraBody, uniquingKeysWith: { _, value in value })
        _ = try JSONValue.object(projected).encodedData()
        guard projected["background"] != true else {
            throw WebSocketDeliveryError(mayHaveBeenSent: false, message: "Background responses require HTTP")
        }
        let previous = sendTail
        let connection = connection
        let current = generation
        var fields = extraBody
        if let laneID { fields["stream_id"] = .string(laneID) }
        let sendFields = fields
        let sendID = UUID()
        pending.append(PendingTurn(id: sendID, key: laneID ?? ""))
        pendingSends += 1
        let task = Task {
            do {
                if let previous { try await ResponsesSendWaiter.wait(for: previous) }
                try Task.checkCancellation()
            } catch {
                throw WebSocketDeliveryError(mayHaveBeenSent: false, message: "Send cancelled before transmission")
            }
            do { try await connection.createResponse(request, extraBody: sendFields) } catch {
                if case OpenAIWebSocketError.messageTooLarge = error {
                    throw WebSocketDeliveryError(mayHaveBeenSent: false, message: String(describing: error))
                }
                throw WebSocketDeliveryError(mayHaveBeenSent: true, message: String(describing: error))
            }
        }
        sendTail = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            if generation == current { pendingSends -= 1 }
        } catch {
            if generation == current {
                pendingSends -= 1
                if let delivery = error as? WebSocketDeliveryError, !delivery.mayHaveBeenSent {
                    pending.removeAll { $0.id == sendID }
                } else {
                    await fail(error)
                }
            }
            throw error
        }
    }

    public func closeLane(_ id: String?) {
        if let lane = lanes.removeValue(forKey: id ?? "") {
            budget.detach(lane.id)
            lane.queue.finish(discarding: true)
        }
    }

    public func close() async {
        recoveryTask?.cancel()
        await fail(CancellationError())
    }

    public func abort() async {
        recoveryTask?.cancel()
        await fail(CancellationError(), abort: true)
    }

    /// Opens a fresh socket and invalidates old lanes. An old send is never carried across generations.
    public func reconnect() async throws {
        try await recover(maxAttempts: 1)
    }

    private func replaceConnection() async throws {
        guard !reconnecting else { throw OpenAIClientError.invalidStream("Reconnect is already in progress") }
        reconnecting = true
        defer { reconnecting = false }
        await fail(OpenAIClientError.invalidStream("WebSocket reconnected"))
        let replacement = try await connector()
        do { try Task.checkCancellation() } catch {
            await replacement.abort()
            throw error
        }
        connection = replacement
        budget = ResponsesBufferBudget(maxEvents: options.maxBufferedEvents, maxBytes: options.maxBufferedBytes)
        generation = UUID()
        lanes.removeAll()
        usedIDs.removeAll()
        responseLanes.removeAll()
        pending.removeAll()
        pendingSends = 0
        sendTail = nil
        closed = false
        reconnecting = false
        _ = try lane()
        startReader()
    }

    public func recover(
        maxAttempts: Int = 1,
        retryDelay: TimeInterval = 0,
        restore: (@Sendable (ResponsesSession) async throws -> Void)? = nil
    ) async throws {
        guard maxAttempts >= 0, retryDelay.isFinite, retryDelay >= 0, recoveryTask == nil else {
            throw OpenAIClientError.invalidConfiguration("Invalid or concurrent WebSocket recovery")
        }
        let attempts = maxAttempts == 0 ? 1 : maxAttempts
        let task = Task { try await performRecovery(maxAttempts: attempts, retryDelay: retryDelay, restore: restore) }
        recoveryTask = task
        defer { recoveryTask = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performRecovery(
        maxAttempts: Int, retryDelay: TimeInterval, restore: (@Sendable (ResponsesSession) async throws -> Void)?
    ) async throws {
        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()
            if attempt > 0, retryDelay > 0 { try await Task.sleep(for: .seconds(retryDelay)) }
            do {
                try await replaceConnection()
                try await restore?(self)
                try Task.checkCancellation()
                return
            } catch {
                await fail(error, abort: true)
                guard attempt + 1 < maxAttempts else { throw error }
            }
        }
    }

    private func startReader() {
        let connection = connection
        let generation = generation
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let queued = try await connection.receiveQueuedResponseEvent()
                    guard let self else {
                        await connection.close()
                        return
                    }
                    try await self.route(queued.event, bytes: queued.bytes, generation: generation)
                }
            } catch { await self?.readerFailed(error, generation: generation) }
        }
    }

    private func route(_ event: ResponseEvent, bytes: Int, generation: UUID) throws {
        guard self.generation == generation, !closed else { return }
        let raw = event.rawValue
        let responseID = event.response?.id ?? raw["response_id"]?.stringValue
        let tagged =
            raw["stream_id"]?.stringValue
            ?? (options.inferUntaggedResponseLanes ? raw["response"]?["stream_id"]?.stringValue : nil)
        var key = tagged ?? (options.inferUntaggedResponseLanes ? responseID.flatMap { responseLanes[$0] } : nil)
        if event.type == "response.created" {
            if let tagged, let index = pending.firstIndex(where: { $0.key == tagged }) {
                pending.remove(at: index)
            } else if key == nil, let index = pending.firstIndex(where: { $0.key == "" }) {
                key = pending.remove(at: index).key
            }
            if let responseID, let key { responseLanes[responseID] = key }
        }
        if options.inferUntaggedResponseLanes, key == nil, event.type == "error", !pending.isEmpty {
            key = pending.removeFirst().key
        }
        let destination = key ?? ""
        // Unclaimed and detached-lane events remain available to the default receiver.
        if let lane = lanes[destination] ?? lanes[""] {
            try budget.reserve(lane.id, bytes: bytes)
            if !lane.queue.yield(QueuedResponseEvent(event: event, bytes: bytes)) {
                budget.consumed(lane.id, bytes: bytes)
                throw OpenAIClientError.streamOverflow
            }
        }
        if ["response.completed", "response.failed", "response.incomplete"].contains(event.type), let responseID {
            responseLanes.removeValue(forKey: responseID)
        }
    }

    private func readerFailed(_ error: any Error, generation: UUID) async {
        guard self.generation == generation else { return }
        await fail(error)
    }
    private func fail(_ error: any Error, abort: Bool = false) async {
        closed = true
        generation = UUID()
        let previousReader = reader
        reader = nil
        sendTail?.cancel()
        for lane in lanes.values { lane.queue.finish(throwing: error) }
        if abort { await connection.abort() } else { await connection.close() }
        previousReader?.cancel()
    }
}

extension ResponsesService {
    /// Opens a managed Responses session with a single reader and optional stream_id lanes.
    public func connectSession(
        options: RequestOptions = .init(), webSocketOptions: WebSocketOptions = .init(),
        sessionOptions: ResponsesSessionOptions = .init(),
        transport: (any OpenAIWebSocketTransport)? = nil
    ) async throws -> ResponsesSession {
        try await ResponsesSession.open(options: sessionOptions) {
            try await connect(options: options, webSocketOptions: webSocketOptions, transport: transport)
        }
    }
}
