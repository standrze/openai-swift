import Foundation

/// An exact JSON number outside the lossless range of Int64 or Double.
/// Use JSONValue.encodedData() to forward numbers beyond Foundation Decimal's range.
public struct JSONNumber: Codable, Sendable, Hashable {
    public let rawValue: String
    public init(_ rawValue: String) throws {
        let text = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
        else {
            throw OpenAIClientError.decoding("Invalid JSON number")
        }
        self.rawValue = text
    }

    public var isInteger: Bool {
        let parts = components
        if parts.digits.allSatisfy({ $0 == "0" }) { return true }
        guard let exponent = Int(parts.exponent) else { return !parts.exponent.hasPrefix("-") }
        let zeros = parts.digits.reversed().prefix(while: { $0 == "0" }).count
        return exponent >= parts.fraction - zeros
    }

    public init(from decoder: any Decoder) throws {
        if let document = OpenAIJSON.source,
            let text = document.field(
                at: decoder.codingPath.map { $0.intValue.map(JSONPathComponent.index) ?? .key($0.stringValue) }
            ).rawString
        {
            try self.init(text)
        } else {
            let value = try decoder.singleValueContainer().decode(Decimal.self)
            try self.init(String(decoding: JSONEncoder().encode(value), as: UTF8.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        let value = try JSONDecoder().decode(Decimal.self, from: Data(rawValue.utf8))
        let rendered = try Self(String(decoding: JSONEncoder().encode(value), as: UTF8.self))
        guard canonical != nil, canonical == rendered.canonical else {
            throw OpenAIClientError.decoding("Number exceeds Foundation's exact numeric range; use encodedData()")
        }
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    var canonical: String? {
        let parts = components
        let digits = String(parts.digits.drop(while: { $0 == "0" }))
        if digits.isEmpty { return "0" }
        guard let exponent = Int(parts.exponent) else { return nil }
        let zeros = digits.reversed().prefix(while: { $0 == "0" }).count
        let (adjusted, overflow) = exponent.addingReportingOverflow(zeros - parts.fraction)
        guard !overflow else { return nil }
        return (rawValue.hasPrefix("-") ? "-" : "") + digits.dropLast(zeros) + "e" + String(adjusted)
    }

    private var components: (digits: String, fraction: Int, exponent: String) {
        let split = rawValue.lowercased().split(separator: "e", omittingEmptySubsequences: false)
        let mantissa = split[0].hasPrefix("-") ? split[0].dropFirst() : split[0][...]
        let decimal = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        return (decimal.joined(), decimal.count == 2 ? decimal[1].count : 0, split.count == 2 ? String(split[1]) : "0")
    }
}

extension JSONValue {
    /// Encodes all dynamic JSON losslessly, including arbitrary-precision numbers.
    public func encodedData() throws -> Data {
        switch self {
        case .rawNumber(let number): return Data(number.rawValue.utf8)
        case .array(let values):
            var data = Data("[".utf8)
            for (index, value) in values.enumerated() {
                if index > 0 { data.append(44) }
                data.append(try value.encodedData())
            }
            data.append(93)
            return data
        case .object(let values):
            var data = Data("{".utf8)
            for (index, key) in values.keys.sorted().enumerated() {
                if index > 0 { data.append(44) }
                data.append(try JSONEncoder().encode(key))
                data.append(58)
                data.append(try values[key]!.encodedData())
            }
            data.append(125)
            return data
        default: return try JSONEncoder().encode(self)
        }
    }
}
