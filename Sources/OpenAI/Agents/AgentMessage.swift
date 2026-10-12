import Foundation

/// A schema-flexible session history message with the Go SDK's text extraction convenience.
public struct AgentMessage: Codable, Sendable, Equatable {
    public let rawValue: JSONValue
    public var outputText: String {
        (rawValue["content"]?.arrayValue ?? []).compactMap {
            $0["type"] == "output_text" ? $0["text"]?.stringValue : nil
        }.joined()
    }
    public init(_ rawValue: JSONValue) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try JSONValue(from: decoder) }
    public func encode(to encoder: any Encoder) throws { try rawValue.encode(to: encoder) }
}
