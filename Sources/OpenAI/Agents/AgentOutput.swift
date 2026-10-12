import Foundation

/// Binds a normalized object-root Agents schema to an application-owned parser.
public struct AgentOutput<Value: Sendable>: Sendable {
    private let schema: JSONValue
    private let parser: @Sendable (Data) throws -> Value

    public init(schema: JSONValue, parse: @escaping @Sendable (Data) throws -> Value) throws {
        guard schema["type"] == "object", ["anyOf", "$ref", "enum", "const"].allSatisfy({ schema[$0] == nil }) else {
            throw OpenAIClientError.invalidConfiguration("Agent output requires an object-root schema")
        }
        self.schema = try AgentOutputSchema.normalize(schema, root: schema)
        parser = parse
    }

    public var format: JSONValue { ["type": "json_schema", "schema": schema] }

    public init(schemaJSON: Data, parse: @escaping @Sendable (Data) throws -> Value) throws {
        try self.init(schema: OpenAIJSON.decode(JSONValue.self, from: schemaJSON), parse: parse)
    }

    public func parseResult(_ result: AgentTurnResult) throws -> AgentParsedTurnResult<Value> {
        do {
            return AgentParsedTurnResult(result: result, output: try parser(Data(result.outputText.utf8)))
        } catch { throw AgentOutputParseError(result: result, cause: error) }
    }

    public func finalResult(_ stream: AgentSessionStream) async throws -> AgentParsedTurnResult<Value> {
        try parseResult(await stream.finalResult())
    }
}

extension AgentOutput where Value: Decodable {
    public init(schema: JSONValue) throws {
        try self.init(schema: schema) { try OpenAIJSON.decode(Value.self, from: $0) }
    }
}

public struct AgentParsedTurnResult<Value: Sendable>: Sendable {
    public let result: AgentTurnResult
    public let output: Value
}

public struct AgentOutputParseError: Error, Sendable, CustomStringConvertible {
    public let result: AgentTurnResult
    public let cause: any Error
    public var description: String { "Cannot parse completed beta agent output" }
}
