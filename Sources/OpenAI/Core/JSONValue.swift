import Foundation

/// A JSON value for provider extensions, schemas, and endpoints without a typed model.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case rawNumber(JSONNumber)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        if let source = OpenAIJSON.source,
            let raw = source.field(
                at: decoder.codingPath.map { $0.intValue.map(JSONPathComponent.index) ?? .key($0.stringValue) }
            ).rawString,
            let number = try? JSONNumber(raw)
        {
            if let integer = Int64(number.rawValue) {
                self = .integer(integer)
            } else if let double = Double(number.rawValue), double.isFinite,
                let rendered = try? JSONNumber(String(decoding: JSONEncoder().encode(double), as: UTF8.self)),
                number.canonical != nil, number.canonical == rendered.canonical
            {
                self = .number(double)
            } else {
                self = .rawNumber(number)
            }
            return
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .rawNumber(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }
    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
    public var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
    public var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }
    public var intValue: Int64? {
        guard case .integer(let value) = self else { return nil }
        return value
    }
    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    /// Decodes this value into an application-owned type.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try OpenAIJSON.decode(type, from: encodedData())
    }

    /// Encodes an application-owned value without an untyped `Any` boundary.
    public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        if let value = value as? JSONValue { return value }
        return try OpenAIJSON.decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
