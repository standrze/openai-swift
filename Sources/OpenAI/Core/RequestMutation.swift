import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Ordered HTTP header edits, applied after client defaults and operation headers.
public enum HeaderMutation: Sendable {
    case set(String, String)
    case add(String, String)
    case delete(String)

    public var name: String {
        switch self {
        case .set(let name, _), .add(let name, _), .delete(let name): return name
        }
    }

    func apply(to request: inout URLRequest) throws {
        let value: String?
        switch self {
        case .set(_, let supplied), .add(_, let supplied): value = supplied
        case .delete: value = nil
        }
        try Self.validate(name: name, value: value)
        switch self {
        case .set(let name, let value): request.setValue(value, forHTTPHeaderField: name)
        case .add(let name, let value): request.addValue(value, forHTTPHeaderField: name)
        case .delete(let name): request.setValue(nil, forHTTPHeaderField: name)
        }
    }

    public static func validate(name: String, value: String?) throws {
        let allowed = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(allowed.contains),
            !(value?.unicodeScalars.contains { ($0.value < 32 && $0.value != 9) || $0.value == 127 } ?? false)
        else { throw OpenAIClientError.invalidConfiguration("Invalid HTTP header") }
    }
}

/// Ordered query edits. Addition retains repeated values; deletion removes every matching name.
public enum QueryMutation: Sendable {
    case set(String, String)
    case add(String, String)
    case delete(String)

    public func apply(to items: inout [URLQueryItem]) {
        switch self {
        case .set(let name, let value):
            items.removeAll { $0.name == name }
            items.append(URLQueryItem(name: name, value: value))
        case .add(let name, let value): items.append(URLQueryItem(name: name, value: value))
        case .delete(let name): items.removeAll { $0.name == name }
        }
    }
}

/// Replaces a serialized operation body, including multipart or undocumented media types.
public struct RequestBodyOverride: Sendable {
    public var contentType: String
    public var data: Data

    public init(contentType: String, data: Data) {
        self.contentType = contentType
        self.data = data
    }
}

extension RequestOptions {
    public var overridesAuthorization: Bool {
        headers.keys.contains { $0.lowercased() == "authorization" }
            || headerMutations.contains { $0.name.lowercased() == "authorization" }
    }

    func apply(to request: inout URLRequest) throws {
        for mutation in headerMutations { try mutation.apply(to: &request) }
        if let bodyOverride {
            try HeaderMutation.validate(name: "Content-Type", value: bodyOverride.contentType)
            request.httpBodyStream = nil
            request.httpBody = bodyOverride.data
            request.setValue(bodyOverride.contentType, forHTTPHeaderField: "Content-Type")
            request.setValue(nil, forHTTPHeaderField: "Content-Length")
        }
    }
}
