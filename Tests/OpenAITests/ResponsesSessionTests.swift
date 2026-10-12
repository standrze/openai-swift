import Foundation
import XCTest

@testable import OpenAI

final class ResponsesSessionTests: XCTestCase, @unchecked Sendable {
    func testGlobalQueueBudgetCountsEventsAcrossLanes() async throws {
        let socket = SessionSocket()
        var options = ResponsesSessionOptions()
        options.maxBufferedEvents = 1
        let session = try await ResponsesSession.open(options: options) { OpenAIJSONConnection(connection: socket) }
        _ = try await session.lane(id: "one")
        _ = try await session.lane(id: "two")
        await socket.push(#"{"type":"response.in_progress","stream_id":"one"}"#)
        await socket.push(#"{"type":"response.in_progress","stream_id":"two"}"#)
        await socket.waitUntilClosed()
    }

    func testConsumingEventsReleasesGlobalBudgetAndLaneFinalResponse() async throws {
        let socket = SessionSocket()
        var options = ResponsesSessionOptions()
        options.maxBufferedEvents = 1
        let session = try await ResponsesSession.open(options: options) { OpenAIJSONConnection(connection: socket) }
        let lane = try await session.lane(id: "one")
        await socket.push(#"{"type":"response.in_progress","stream_id":"one"}"#)
        var events = lane.events.makeAsyncIterator()
        let first = try await events.next()
        XCTAssertEqual(first?.type, "response.in_progress")
        await socket.push(
            #"{"type":"response.completed","stream_id":"one","response":{"id":"done","status":"completed","output":[]}}"#
        )
        let final = try await lane.finalResponse()
        XCTAssertEqual(final.id, "done")
        await session.abort()
    }

    func testByteBudgetFailsBeforeEnqueuingOversizedEvent() async throws {
        let socket = SessionSocket()
        var options = ResponsesSessionOptions()
        options.maxBufferedBytes = 1
        let session = try await ResponsesSession.open(options: options) { OpenAIJSONConnection(connection: socket) }
        let lane = try await session.lane(id: "one")
        await socket.push(#"{"type":"response.in_progress","stream_id":"one"}"#)
        await socket.waitUntilClosed()
        var events = lane.events.makeAsyncIterator()
        do {
            _ = try await events.next()
            XCTFail("Expected byte overflow")
        } catch OpenAIClientError.streamOverflow {}
    }

    func testByteBudgetIncludesOriginalWireWhitespace() async throws {
        let socket = SessionSocket()
        let compact = #"{"type":"response.in_progress","stream_id":"one"}"#
        var options = ResponsesSessionOptions()
        options.maxBufferedBytes = compact.utf8.count + 1
        let session = try await ResponsesSession.open(options: options) { OpenAIJSONConnection(connection: socket) }
        let lane = try await session.lane(id: "one")
        await socket.push("    " + compact)
        await socket.waitUntilClosed()
        var events = lane.events.makeAsyncIterator()
        do {
            _ = try await events.next()
            XCTFail("Wire bytes exceed the budget")
        } catch OpenAIClientError.streamOverflow {}
    }

    func testRoutesInterleavedLanesAndDefaultFIFO() async throws {
        let socket = SessionSocket()
        var options = ResponsesSessionOptions()
        options.inferUntaggedResponseLanes = true
        let session = try await ResponsesSession.open(options: options) { OpenAIJSONConnection(connection: socket) }
        let first = try await session.lane(id: "first")
        let second = try await session.lane(id: "second")
        let plain = try await session.lane()
        try await first.send(ResponseRequest(model: "m", input: .text("one")))
        try await plain.send(ResponseRequest(model: "m", input: .text("default")))
        try await second.send(ResponseRequest(model: "m", input: .text("two")))
        await socket.push(#"{"type":"response.created","stream_id":"second","response":{"id":"r2","output":[]}}"#)
        await socket.push(#"{"type":"response.created","stream_id":"first","response":{"id":"r1","output":[]}}"#)
        await socket.push(#"{"type":"response.created","response":{"id":"rp","output":[]}}"#)
        await socket.push(
            #"{"type":"response.output_text.delta","response_id":"r1","output_index":0,"content_index":0,"delta":"one"}"#
        )
        var firstEvents = first.events.makeAsyncIterator()
        var secondEvents = second.events.makeAsyncIterator()
        var defaultEvents = plain.events.makeAsyncIterator()
        let createdFirst = try await firstEvents.next()
        let createdSecond = try await secondEvents.next()
        let createdDefault = try await defaultEvents.next()
        let delta = try await firstEvents.next()
        XCTAssertEqual(createdFirst?.response?.id, "r1")
        XCTAssertEqual(createdSecond?.response?.id, "r2")
        XCTAssertEqual(createdDefault?.response?.id, "rp")
        XCTAssertEqual(delta?.textDelta, "one")
        let sent = await socket.sent
        XCTAssertEqual(sent.count, 3)
        let firstJSON = try JSONDecoder().decode(JSONValue.self, from: sent[0].bytes)
        XCTAssertEqual(firstJSON["stream_id"], "first")
        await session.close()
    }

    func testLaneValidationAndLifetimeLimit() async throws {
        let socket = SessionSocket()
        var options = ResponsesSessionOptions()
        options.maxLanes = 1
        let session = try await ResponsesSession.open(options: options) { OpenAIJSONConnection(connection: socket) }
        do {
            _ = try await session.lane(id: "bad/slash")
            XCTFail("Invalid lane accepted")
        } catch {}
        let lane = try await session.lane(id: "valid")
        await lane.close()
        do {
            _ = try await session.lane(id: "valid")
            XCTFail("Closed lane reused")
        } catch {}
        do {
            _ = try await session.lane(id: "another")
            XCTFail("Lifetime lane limit exceeded")
        } catch {}
        await session.close()
    }

    func testOverflowFailsExplicitlyAndClosesSharedSocket() async throws {
        let socket = SessionSocket()
        var options = ResponsesSessionOptions()
        options.maxBufferedEventsPerLane = 1
        let session = try await ResponsesSession.open(options: options) { OpenAIJSONConnection(connection: socket) }
        let lane = try await session.lane(id: "one")
        await socket.push(#"{"type":"response.in_progress","stream_id":"one"}"#)
        await socket.push(#"{"type":"response.in_progress","stream_id":"one"}"#)
        await socket.waitUntilClosed()
        var iterator = lane.events.makeAsyncIterator()
        _ = try await iterator.next()
        do {
            _ = try await iterator.next()
            XCTFail("Overflow silently dropped")
        } catch {
            guard case OpenAIClientError.streamOverflow = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testReconnectDoesNotReplayRequestsAndRestoreRuns() async throws {
        let sockets = SessionSocketFactory()
        let session = try await ResponsesSession.open { await sockets.connect() }
        let lane = try await session.lane(id: "one")
        try await lane.send(ResponseRequest(model: "m", input: .text("never replay")))
        try await session.recover { restored in _ = try await restored.lane(id: "one") }
        let connections = await sockets.sockets
        XCTAssertEqual(connections.count, 2)
        let original = await connections[0].sent
        let replacement = await connections[1].sent
        XCTAssertEqual(original.count, 1)
        XCTAssertTrue(replacement.isEmpty)
        await session.close()
    }

    func testFailedSendReportsAmbiguousDelivery() async throws {
        let socket = SessionSocket(failSend: true)
        let session = try await ResponsesSession.open { OpenAIJSONConnection(connection: socket) }
        let lane = try await session.lane()
        do {
            try await lane.send(ResponseRequest(model: "m", input: .text("x")))
            XCTFail("Failed send succeeded")
        } catch let error as WebSocketDeliveryError { XCTAssertTrue(error.mayHaveBeenSent) }
        await session.close()
    }

    func testCancelledReceiveLeavesLaneAndReaderUsable() async throws {
        let socket = SessionSocket()
        let session = try await ResponsesSession.open { OpenAIJSONConnection(connection: socket) }
        let lane = try await session.lane(id: "one")
        let receive = Task {
            var events = lane.events.makeAsyncIterator()
            return try await events.next()
        }
        try await Task.sleep(for: .milliseconds(20))
        receive.cancel()
        do {
            _ = try await receive.value
            XCTFail("Receive cancellation ignored")
        } catch is CancellationError {}
        await socket.push(#"{"type":"response.in_progress","stream_id":"one"}"#)
        var events = lane.events.makeAsyncIterator()
        let resumed = try await events.next()
        XCTAssertEqual(resumed?.type, "response.in_progress")
        await session.abort()
    }

    func testUnclaimedAndDetachedEventsReachDefaultReceiver() async throws {
        let socket = SessionSocket()
        var options = ResponsesSessionOptions()
        options.maxLanes = 0
        options.maxPendingSends = 0
        let session = try await ResponsesSession.open(options: options) { OpenAIJSONConnection(connection: socket) }
        await socket.push(#"{"type":"response.in_progress","stream_id":"unclaimed"}"#)
        let defaults = try await session.lane()
        var events = defaults.events.makeAsyncIterator()
        let unclaimed = try await events.next()
        XCTAssertEqual(unclaimed?.rawValue["stream_id"], "unclaimed")
        let lane = try await session.lane(id: "one")
        do {
            _ = try await session.lane(id: "one")
            XCTFail("Duplicate attachment accepted")
        } catch {}
        await lane.close()
        await socket.push(#"{"type":"response.in_progress","stream_id":"one"}"#)
        let detached = try await events.next()
        XCTAssertEqual(detached?.rawValue["stream_id"], "one")
        await session.abort()
    }

    func testUntaggedEventsRemainOnDefaultReceiver() async throws {
        let socket = SessionSocket()
        let session = try await ResponsesSession.open { OpenAIJSONConnection(connection: socket) }
        let lane = try await session.lane(id: "one")
        await socket.push(#"{"type":"response.created","stream_id":"one","response":{"id":"r"}}"#)
        var named = lane.events.makeAsyncIterator()
        _ = try await named.next()
        await socket.push(#"{"type":"response.output_text.delta","response_id":"r","delta":"default"}"#)
        let defaults = try await session.lane()
        var events = defaults.events.makeAsyncIterator()
        let event = try await events.next()
        XCTAssertEqual(event?.textDelta, "default")
        await session.abort()
    }

    func testRecoveryRetryDelayAndFailedRestoreDisposal() async throws {
        let sockets = SessionSocketFactory()
        let session = try await ResponsesSession.open { await sockets.connect() }
        let restores = CancellationRecorder()
        try await session.recover(maxAttempts: 2, retryDelay: 0.01) { _ in
            restores.record()
            if restores.count == 1 { throw URLError(.networkConnectionLost) }
        }
        let connections = await sockets.sockets
        XCTAssertEqual(connections.count, 3)
        XCTAssertEqual(restores.count, 2)
        await connections[1].waitUntilClosed()
        await session.abort()
    }

    func testCloseCancelsRecoveryOpening() async throws {
        let factory = RecoverySocketFactory()
        let session = try await ResponsesSession.open { try await factory.connect() }
        let recovery = Task { try await session.reconnect() }
        await factory.waitUntilOpening()
        await session.abort()
        do {
            try await recovery.value
            XCTFail("Closed recovery reopened connection")
        } catch is CancellationError {}
        do {
            _ = try await session.lane(id: "after")
            XCTFail("Closed session resurrected")
        } catch {}
    }

    func testCancelledQueuedSendDoesNotAbortOrWaitForEarlierWrite() async throws {
        let socket = SessionSocket(holdFirstSend: true)
        let session = try await ResponsesSession.open { OpenAIJSONConnection(connection: socket) }
        let lane = try await session.lane()
        let first = Task { try await lane.send(ResponseRequest(model: "m", input: "first")) }
        await socket.waitUntilSendHeld()
        let waiter = Task { try await lane.send(ResponseRequest(model: "m", input: "cancelled")) }
        try await Task.sleep(for: .milliseconds(10))
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("Cancelled queued send completed")
        } catch let error as WebSocketDeliveryError {
            XCTAssertFalse(error.mayHaveBeenSent)
        }
        XCTAssertFalse(first.isCancelled)
        let beforeRelease = await socket.sent
        XCTAssertEqual(beforeRelease.count, 1)
        await socket.releaseSend()
        try await first.value
        try await lane.send(ResponseRequest(model: "m", input: "after cancellation"))
        let sent = await socket.sent
        XCTAssertEqual(sent.count, 2)
        await session.abort()
    }

}

private actor SessionSocketFactory {
    var sockets: [SessionSocket] = []
    func connect() -> OpenAIJSONConnection {
        let socket = SessionSocket()
        sockets.append(socket)
        return OpenAIJSONConnection(connection: socket)
    }
}
private actor SessionSocket: OpenAIWebSocketConnection {
    var sent: [WebSocketMessage] = []
    private var queue: [WebSocketMessage] = []
    private var waiter: CheckedContinuation<WebSocketMessage, any Error>?
    private var closedWaiters: [CheckedContinuation<Void, Never>] = []
    private var closed = false
    private let failSend: Bool
    private let holdFirstSend: Bool
    private var heldSend: CheckedContinuation<Void, any Error>?
    private var sendObservers: [CheckedContinuation<Void, Never>] = []
    init(failSend: Bool = false, holdFirstSend: Bool = false) {
        self.failSend = failSend
        self.holdFirstSend = holdFirstSend
    }
    func send(_ message: WebSocketMessage) async throws {
        if failSend || closed { throw URLError(.networkConnectionLost) }
        sent.append(message)
        if holdFirstSend, sent.count == 1 {
            try await withCheckedThrowingContinuation { continuation in
                heldSend = continuation
                for observer in sendObservers { observer.resume() }
                sendObservers.removeAll()
            }
        }
    }
    func waitUntilSendHeld() async {
        if heldSend != nil { return }
        await withCheckedContinuation { sendObservers.append($0) }
    }
    func releaseSend() {
        heldSend?.resume()
        heldSend = nil
    }
    func push(_ json: String) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: .text(json))
        } else {
            queue.append(.text(json))
        }
    }
    func receive() async throws -> WebSocketMessage {
        if !queue.isEmpty { return queue.removeFirst() }
        if closed { throw OpenAIWebSocketError.closed(code: 1000, reason: nil) }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close(code: WebSocketCloseCode, reason: Data?) {
        closed = true
        heldSend?.resume(throwing: CancellationError())
        heldSend = nil
        waiter?.resume(throwing: OpenAIWebSocketError.closed(code: code.rawValue, reason: reason))
        waiter = nil
        for waiter in closedWaiters { waiter.resume() }
        closedWaiters.removeAll()
    }
    func waitUntilClosed() async {
        if closed { return }
        await withCheckedContinuation { closedWaiters.append($0) }
    }
}

private actor RecoverySocketFactory {
    private var count = 0
    private var waiter: CheckedContinuation<Void, Never>?
    func connect() async throws -> OpenAIJSONConnection {
        count += 1
        if count > 1 {
            waiter?.resume()
            waiter = nil
            try await Task.sleep(for: .seconds(10))
        }
        return OpenAIJSONConnection(connection: SessionSocket())
    }
    func waitUntilOpening() async {
        if count > 1 { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
