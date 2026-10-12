import Foundation

/// Provisional fields and sparse indices, independent of the server's final response.
public struct ResponseAccumulatorDetails: Sendable {
    public let streamID: String?
    public let responseID: String?
    public let terminalEvent: String?
    public let response: [String: JSONValue]
    public let output: [ResponseAccumulatedDetails]
}

public struct ResponseAccumulatedDetails: Sendable {
    public let outputIndex: Int
    public let item: [String: JSONValue]
    public let content: [Int: [String: JSONValue]]
    public let annotations: [Int: [Int: JSONValue]]
}
