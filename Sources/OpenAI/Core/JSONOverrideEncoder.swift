import Foundation

/// Applies field overrides across flattened allOf/anyOf model components.
public struct JSONOverrideEncoder: Encoder {
    private let base: any Encoder
    private let overrides: [String: JSONFieldOverride]
    public var codingPath: [any CodingKey] { base.codingPath }
    public var userInfo: [CodingUserInfoKey: Any] { base.userInfo }

    public init(_ base: any Encoder, overrides: [String: JSONFieldOverride]) {
        self.base = base
        self.overrides = overrides
    }

    public func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(OverrideContainer(base: base.container(keyedBy: type), overrides: overrides))
    }
    public func unkeyedContainer() -> any UnkeyedEncodingContainer { base.unkeyedContainer() }
    public func singleValueContainer() -> any SingleValueEncodingContainer { base.singleValueContainer() }
}

private struct OverrideContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    var base: KeyedEncodingContainer<Key>
    let overrides: [String: JSONFieldOverride]
    var codingPath: [any CodingKey] { base.codingPath }

    mutating func encodeNil(forKey key: Key) throws {
        try encodeJSONField(JSONValue.null, forKey: key, to: &base, overrides: overrides)
    }
    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        try encodeJSONField(value, forKey: key, to: &base, overrides: overrides)
    }
    mutating func encode(_ value: Bool, forKey key: Key) throws {
        try encodeJSONField(value, forKey: key, to: &base, overrides: overrides)
    }
    mutating func encode(_ value: String, forKey key: Key) throws {
        try encodeJSONField(value, forKey: key, to: &base, overrides: overrides)
    }
    mutating func encode(_ value: Double, forKey key: Key) throws {
        try encodeJSONField(value, forKey: key, to: &base, overrides: overrides)
    }
    mutating func encode(_ value: Float, forKey key: Key) throws {
        try encodeJSONField(value, forKey: key, to: &base, overrides: overrides)
    }
    mutating func encode(_ value: Int, forKey key: Key) throws {
        try encodeJSONField(value, forKey: key, to: &base, overrides: overrides)
    }
    mutating func encode(_ value: Int8, forKey key: Key) throws {
        try encodeJSONField(value, forKey: key, to: &base, overrides: overrides)
    }
    mutating func encode(_ value: Int16, forKey key: Key) throws {
        try encodeJSONField(value, forKey: key, to: &base, overrides: overrides)
    }
    mutating func encode(_ value: Int32, forKey key: Key) throws {
        try encodeJSONField(value, forKey: key, to: &base, overrides: overrides)
    }
    mutating func encode(_ value: Int64, forKey key: Key) throws {
        try encodeJSONField(value, forKey: key, to: &base, overrides: overrides)
    }
    mutating func encode(_ value: UInt, forKey key: Key) throws {
        try encodeJSONField(value, forKey: key, to: &base, overrides: overrides)
    }
    mutating func encode(_ value: UInt8, forKey key: Key) throws {
        try encodeJSONField(value, forKey: key, to: &base, overrides: overrides)
    }
    mutating func encode(_ value: UInt16, forKey key: Key) throws {
        try encodeJSONField(value, forKey: key, to: &base, overrides: overrides)
    }
    mutating func encode(_ value: UInt32, forKey key: Key) throws {
        try encodeJSONField(value, forKey: key, to: &base, overrides: overrides)
    }
    mutating func encode(_ value: UInt64, forKey key: Key) throws {
        try encodeJSONField(value, forKey: key, to: &base, overrides: overrides)
    }
    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key)
        -> KeyedEncodingContainer<NestedKey>
    {
        base.nestedContainer(keyedBy: type, forKey: key)
    }
    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        base.nestedUnkeyedContainer(forKey: key)
    }
    mutating func superEncoder() -> any Encoder { base.superEncoder() }
    mutating func superEncoder(forKey key: Key) -> any Encoder { base.superEncoder(forKey: key) }
}
