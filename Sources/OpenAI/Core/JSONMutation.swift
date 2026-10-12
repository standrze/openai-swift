import Foundation

/// A component in a JSON field path. String keys never interpret dots as separators.
public enum JSONPathComponent: Sendable, Hashable {
    case key(String)
    case index(Int)
}

/// A deep request-body override. Deleting an array element shifts subsequent indices.
public enum JSONMutation: Sendable {
    case set([JSONPathComponent], JSONValue)
    case delete([JSONPathComponent])

    /// Applies this mutation or throws when the path has the wrong shape.
    public func apply(to value: inout JSONValue) throws {
        switch self {
        case .set(let path, let replacement): try value.mutate(path[...], replacement: replacement)
        case .delete(let path): try value.mutate(path[...], replacement: nil)
        }
    }
}

extension JSONValue {
    fileprivate mutating func mutate(_ path: ArraySlice<JSONPathComponent>, replacement: JSONValue?) throws {
        guard let component = path.first else {
            guard let replacement else {
                throw OpenAIClientError.invalidConfiguration("Cannot delete the JSON root")
            }
            self = replacement
            return
        }
        let tail = path.dropFirst()
        switch component {
        case .key(let key):
            guard case .object(var object) = self else {
                throw OpenAIClientError.invalidConfiguration("JSON path requires an object at \(key)")
            }
            if tail.isEmpty {
                object[key] = replacement
            } else {
                if object[key] == nil, replacement == nil { return }
                var child = object[key] ?? .object([:])
                try child.mutate(tail, replacement: replacement)
                object[key] = child
            }
            self = .object(object)
        case .index(let index):
            guard case .array(var array) = self, array.indices.contains(index) else {
                throw OpenAIClientError.invalidConfiguration("JSON array index out of bounds: \(index)")
            }
            if tail.isEmpty, replacement == nil {
                array.remove(at: index)
            } else {
                try array[index].mutate(tail, replacement: replacement)
            }
            self = .array(array)
        }
    }
}

/// Distinguishes an omitted field, explicit null, a typed value, and an arbitrary wire override.
/// Use the keyed-container overload below to omit a key; omission has no standalone JSON representation.
public enum JSONParameter<Value: Encodable & Sendable>: Encodable, Sendable {
    case omitted
    case null
    case value(Value)
    case override(JSONValue)

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .omitted:
            throw OpenAIClientError.invalidConfiguration("Encode omitted parameters through a keyed container")
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .value(let value): try value.encode(to: encoder)
        case .override(let value): try value.encode(to: encoder)
        }
    }
}

extension KeyedEncodingContainer {
    /// Encodes a parameter without collapsing omission and explicit null.
    public mutating func encode<Value>(_ parameter: JSONParameter<Value>, forKey key: Key) throws {
        if case .omitted = parameter { return }
        try encodeIfPresent(parameter, forKey: key)
    }
}
