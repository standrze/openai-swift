import Foundation

/// Exact JSON source and field presence, independent of a decoded model's known properties.
/// Numbers retain their original decimal spelling. Duplicate object keys follow last-key-wins semantics.
public struct JSONDocument: Sendable {
    public enum Presence: Sendable, Equatable { case missing, null, value, invalid }
    public struct Field: Sendable {
        public let presence: Presence
        public let rawData: Data?
        public var rawString: String? { rawData.map { String(decoding: $0, as: UTF8.self) } }
        public func decode<Value: Decodable>(_ type: Value.Type = Value.self) throws -> Value {
            guard let rawData else { throw OpenAIClientError.decoding("JSON field is missing") }
            return try JSONDecoder().decode(type, from: rawData)
        }
    }

    public let data: Data
    private let root: Node

    public init(data: Data, rejectDuplicateKeys: Bool = false) throws {
        var scanner = Scanner(bytes: Array(data), rejectDuplicateKeys: rejectDuplicateKeys)
        root = try scanner.value(depth: 0)
        scanner.whitespace()
        guard scanner.offset == scanner.bytes.count else { throw OpenAIClientError.decoding("Trailing JSON bytes") }
        self.data = Data(scanner.bytes)
    }

    public func field(at path: [JSONPathComponent] = []) -> Field {
        var node = root
        for component in path {
            switch component {
            case .key(let key):
                guard let child = node.object[key] else { return Field(presence: .missing, rawData: nil) }
                node = child
            case .index(let index):
                guard node.array.indices.contains(index) else { return Field(presence: .missing, rawData: nil) }
                node = node.array[index]
            }
        }
        return Field(presence: node.isNull ? .null : .value, rawData: data.subdata(in: node.range))
    }

    /// Returns raw fields absent from the caller's known wire-key set.
    public func extraFields(knownKeys: Set<String>, at path: [JSONPathComponent] = []) throws -> [String: Field] {
        guard let raw = field(at: path).rawData else { return [:] }
        let object = try JSONDocument(data: raw)
        return Dictionary(
            uniqueKeysWithValues: object.root.object.keys.filter { !knownKeys.contains($0) }.map {
                ($0, object.field(at: [.key($0)]))
            })
    }
}

extension JSONDocument {
    fileprivate struct Node: Sendable {
        let range: Range<Int>
        var isNull = false
        var object: [String: Node] = [:]
        var array: [Node] = []
    }

    // Foundation decodes strings; this scanner only tracks source spans and validates JSON structure/numbers.
    fileprivate struct Scanner {
        let bytes: [UInt8]
        var rejectDuplicateKeys = false
        var offset = 0
        mutating func whitespace() {
            while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
        }
        mutating func consume(_ byte: UInt8) throws {
            whitespace()
            guard offset < bytes.count, bytes[offset] == byte else { throw invalid() }
            offset += 1
        }
        func invalid() -> OpenAIClientError { .decoding("Invalid JSON at byte \(offset)") }
        mutating func string() throws -> String {
            let start = offset
            try consume(34)
            var escaped = false
            while offset < bytes.count {
                let byte = bytes[offset]
                offset += 1
                if !escaped, byte == 34 {
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
                }
                if !escaped, byte == 92 { escaped = true } else { escaped = false }
            }
            throw invalid()
        }
        mutating func value(depth: Int) throws -> Node {
            whitespace()
            guard depth < 512, offset < bytes.count else { throw invalid() }
            let start = offset
            var object: [String: Node] = [:]
            var array: [Node] = []
            var isNull = false
            switch bytes[offset] {
            case 123:
                offset += 1
                whitespace()
                if offset < bytes.count, bytes[offset] != 125 {
                    while true {
                        whitespace()
                        let key = try string()
                        try consume(58)
                        if rejectDuplicateKeys, object[key] != nil { throw invalid() }
                        object[key] = try value(depth: depth + 1)
                        whitespace()
                        guard offset < bytes.count else { throw invalid() }
                        if bytes[offset] != 44 { break }
                        offset += 1
                    }
                }
                try consume(125)
            case 91:
                offset += 1
                whitespace()
                if offset < bytes.count, bytes[offset] != 93 {
                    while true {
                        array.append(try value(depth: depth + 1))
                        whitespace()
                        guard offset < bytes.count else { throw invalid() }
                        if bytes[offset] != 44 { break }
                        offset += 1
                    }
                }
                try consume(93)
            case 34: _ = try string()
            default:
                while offset < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
                let token = String(decoding: bytes[start..<offset], as: UTF8.self)
                isNull = token == "null"
                guard
                    ["null", "true", "false"].contains(token)
                        || token.range(
                            of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#,
                            options: .regularExpression) != nil
                else { throw invalid() }
            }
            return Node(range: start..<offset, isNull: isNull, object: object, array: array)
        }
    }
}
