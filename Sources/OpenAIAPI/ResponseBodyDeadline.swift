import Foundation
import OpenAI
import OpenAPIRuntime

func responseBody(_ body: HTTPBody?, until deadline: Date?) -> HTTPBody? {
    guard let body, let deadline else { return body }
    let pair = AsyncThrowingStream<ArraySlice<UInt8>, any Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
    let task = Task {
        do {
            try await RequestDeadline.run(until: deadline) {
                for try await chunk in body {
                    try Task.checkCancellation()
                    if case .dropped = pair.continuation.yield(chunk) { throw OpenAIClientError.streamOverflow }
                }
            }
            pair.continuation.finish()
        } catch { pair.continuation.finish(throwing: error) }
    }
    pair.continuation.onTermination = { @Sendable _ in task.cancel() }
    return HTTPBody(pair.stream, length: body.length, iterationBehavior: .single)
}
