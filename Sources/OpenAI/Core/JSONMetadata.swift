import Foundation

/// A generated model's original JSON, known-field states, and unknown fields.
/// This state is excluded from encoded requests. Use `OpenAIJSON.decode` to retain exact numeric spelling.
public struct JSONMetadata: Sendable, Hashable {
    public private(set) var rawData: Data?
    public private(set) var knownKeys: Set<String>
    private var invalidKeys: Set<String> = []
    private var unmatchedKeys: Set<String> = []

    public init() {
        rawData = nil
        knownKeys = []
    }

    public init(from decoder: any Decoder, knownKeys: Set<String>) throws {
        self.knownKeys = knownKeys
        if let document = OpenAIJSON.source {
            rawData = document.field(at: decoder.codingPath.map(JSONPathComponent.init)).rawData
        } else {
            rawData = try? JSONEncoder().encode(JSONValue(from: decoder))
        }
    }

    public var rawJSON: String? { rawData.map { String(decoding: $0, as: UTF8.self) } }
    public var matchesSchema: Bool { invalidKeys.isEmpty && unmatchedKeys.isEmpty }

    /// A missing, null, malformed, or valid known field, including its original bytes.
    public func field(_ name: String) -> JSONDocument.Field {
        let original = (try? rawData.map { try JSONDocument(data: $0) })?.field(at: [.key(name)])
        return JSONDocument.Field(
            presence: invalidKeys.contains(name) ? .invalid : original?.presence ?? .missing,
            rawData: original?.rawData)
    }

    public var extraFields: [String: JSONDocument.Field] {
        guard let rawData, let document = try? JSONDocument(data: rawData) else { return [:] }
        return (try? document.extraFields(knownKeys: knownKeys)) ?? [:]
    }

    fileprivate mutating func invalid(_ name: String) { invalidKeys.insert(name) }
    fileprivate mutating func unmatched(_ name: String) { unmatchedKeys.insert(name) }
}

/// A Codable model with field metadata and the same zero-value fallback used by the Go SDK.
public protocol JSONModel: JSONDefaultValue {
    var jsonMetadata: JSONMetadata { get set }
    var jsonOverrides: [String: JSONFieldOverride] { get set }
}

/// The value used for an absent, null, or malformed nonoptional response field.
public protocol JSONDefaultValue {
    static var jsonDefaultValue: Self { get }
}

/// Open string enums preserve new wire values while retaining their documented cases.
public protocol JSONStringEnum: RawRepresentable, CaseIterable, JSONDefaultValue where RawValue == String {}

extension JSONStringEnum {
    public static var jsonDefaultValue: Self { Self(rawValue: "")! }
    public var isKnown: Bool { Self.allCases.contains { $0.rawValue == rawValue } }
    fileprivate var matchesConstant: Bool { Self.allCases.count != 1 || isKnown }
}

/// Decodes models while making the original JSON available to every nested model and union.
public enum OpenAIJSON {
    @TaskLocal public static var source: JSONDocument?

    public static func decode<Value: Decodable>(
        _ type: Value.Type, from data: Data, using decoder: JSONDecoder = JSONDecoder()
    ) throws -> Value {
        try $source.withValue(JSONDocument(data: data)) { try decoder.decode(type, from: data) }
    }
}

extension JSONPathComponent {
    fileprivate init(_ key: any CodingKey) {
        self = key.intValue.map(Self.index) ?? .key(key.stringValue)
    }
}

public func defaultJSONValue<Value: JSONDefaultValue>(_ type: Value.Type) -> Value { Value.jsonDefaultValue }

/// Used by generated decoders; malformed fields preserve their raw bytes and set `.invalid` metadata.
public func decodeJSONField<Value: Decodable & JSONDefaultValue, Key: CodingKey>(
    _ type: Value.Type, forKey key: Key, from container: KeyedDecodingContainer<Key>, metadata: inout JSONMetadata
) throws -> Value {
    guard container.contains(key), try !container.decodeNil(forKey: key) else {
        metadata.unmatched(key.stringValue)
        return Value.jsonDefaultValue
    }
    do {
        let value = try container.decode(type, forKey: key)
        if let value = value as? any JSONStringEnum, !value.matchesConstant { metadata.unmatched(key.stringValue) }
        if let value = value as? any JSONIntegerEnum, !value.matchesConstant { metadata.unmatched(key.stringValue) }
        return value
    } catch let error as DecodingError {
        if case .dataCorrupted = error, Task.isCancelled { throw CancellationError() }
        metadata.invalid(key.stringValue)
        return Value.jsonDefaultValue
    }
}

public func decodeJSONFieldIfPresent<Value: Decodable, Key: CodingKey>(
    _ type: Value.Type, forKey key: Key, from container: KeyedDecodingContainer<Key>, metadata: inout JSONMetadata
) throws -> Value? {
    do { return try container.decodeIfPresent(type, forKey: key) } catch is DecodingError {
        metadata.invalid(key.stringValue)
        return nil
    }
}

/// Rejects incomplete union candidates so they cannot mask later variants or unknown future objects.
public func decodeJSONUnionCase<Value: Decodable>(from decoder: any Decoder) throws -> Value {
    let value = try Value(from: decoder)
    let matches: Bool
    if let model = value as? any JSONModel {
        matches = model.jsonMetadata.matchesSchema
    } else if let enumeration = value as? any JSONStringEnum {
        matches = enumeration.matchesConstant
    } else {
        matches = true
    }
    guard matches else {
        throw DecodingError.typeMismatch(
            type(of: value), .init(codingPath: decoder.codingPath, debugDescription: "Union schema does not match"))
    }
    return value
}

extension String: JSONDefaultValue { public static var jsonDefaultValue: Self { "" } }
extension Bool: JSONDefaultValue { public static var jsonDefaultValue: Self { false } }
extension Int: JSONDefaultValue { public static var jsonDefaultValue: Self { 0 } }
extension Int32: JSONDefaultValue { public static var jsonDefaultValue: Self { 0 } }
extension Int64: JSONDefaultValue { public static var jsonDefaultValue: Self { 0 } }
extension Double: JSONDefaultValue { public static var jsonDefaultValue: Self { 0 } }
extension Float: JSONDefaultValue { public static var jsonDefaultValue: Self { 0 } }
extension Date: JSONDefaultValue { public static var jsonDefaultValue: Self { Date(timeIntervalSince1970: 0) } }
extension Data: JSONDefaultValue { public static var jsonDefaultValue: Self { Data() } }
extension Array: JSONDefaultValue { public static var jsonDefaultValue: Self { [] } }
extension Dictionary: JSONDefaultValue { public static var jsonDefaultValue: Self { [:] } }
extension Optional: JSONDefaultValue { public static var jsonDefaultValue: Self { nil } }
extension JSONValue: JSONDefaultValue { public static var jsonDefaultValue: Self { .null } }

public struct JSONCodingKey: CodingKey {
    public var stringValue: String
    public var intValue: Int?
    public init(stringValue: String) { self.stringValue = stringValue }
    public init(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

public func encodeEmptyJSONObject(to encoder: any Encoder) throws {
    _ = encoder.container(keyedBy: JSONCodingKey.self)
}

/// A generated request field can be omitted, explicitly null, or replaced with arbitrary JSON.
public enum JSONFieldOverride: Sendable, Hashable {
    case omitted
    case null
    case value(JSONValue)
}

public func encodeJSONField<Value: Encodable, Key: CodingKey>(
    _ value: Value, forKey key: Key, to container: inout KeyedEncodingContainer<Key>,
    overrides: [String: JSONFieldOverride]
) throws {
    switch overrides[key.stringValue] {
    case .omitted: break
    case .null: try container.encodeNil(forKey: key)
    case .value(let replacement): try container.encode(replacement, forKey: key)
    case nil: try container.encode(value, forKey: key)
    }
}

public func encodeJSONFieldIfPresent<Value: Encodable, Key: CodingKey>(
    _ value: Value?, forKey key: Key, to container: inout KeyedEncodingContainer<Key>,
    overrides: [String: JSONFieldOverride]
) throws {
    if let override = overrides[key.stringValue] {
        try encodeJSONField(value, forKey: key, to: &container, overrides: [key.stringValue: override])
    } else {
        try container.encodeIfPresent(value, forKey: key)
    }
}

public func encodeJSONExtras(
    _ overrides: [String: JSONFieldOverride], knownKeys: Set<String>, to encoder: any Encoder
) throws {
    guard !overrides.isEmpty else { return }
    var container = encoder.container(keyedBy: JSONCodingKey.self)
    for (name, value) in overrides where !knownKeys.contains(name) {
        try encodeJSONField(
            JSONValue.null, forKey: JSONCodingKey(stringValue: name), to: &container, overrides: [name: value])
    }
}

public func decodeJSONDiscriminator(_ name: String, from decoder: any Decoder) -> String? {
    guard let container = try? decoder.container(keyedBy: JSONCodingKey.self) else { return nil }
    return try? container.decode(String.self, forKey: JSONCodingKey(stringValue: name))
}

public func unknownJSONUnion(from decoder: any Decoder, matches: [Any?]) throws -> RawJSONValue? {
    guard matches.allSatisfy({ $0 == nil }) else { return nil }
    return try RawJSONValue(from: decoder)
}

public func encodeUnknownJSONUnion(_ value: RawJSONValue?, to encoder: any Encoder) throws {
    try value?.encode(to: encoder)
}

extension JSONMetadata {
    public mutating func mergeKnownFields(from values: [Any?]) {
        knownKeys = []
        for case let model as any JSONModel in values.compactMap({ $0 }) {
            knownKeys.formUnion(model.jsonMetadata.knownKeys)
        }
    }
}

/// Open integer enums retain new wire values, including a zero response default.
public protocol JSONIntegerEnum: RawRepresentable, CaseIterable, JSONDefaultValue where RawValue == Int {}

extension JSONIntegerEnum {
    public static var jsonDefaultValue: Self { Self(rawValue: 0)! }
    public var isKnown: Bool { Self.allCases.contains { $0.rawValue == rawValue } }
    fileprivate var matchesConstant: Bool { Self.allCases.count != 1 || isKnown }
}
