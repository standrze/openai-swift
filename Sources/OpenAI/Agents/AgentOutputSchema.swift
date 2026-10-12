import Foundation

/// Matches the pinned Go helper's normalization; the API validates remaining schema constraints.
enum AgentOutputSchema {
    static func normalize(_ value: JSONValue, root: JSONValue) throws -> JSONValue {
        guard var schema = value.objectValue else { throw invalid("Schema must be an object") }
        let unsupported: Set<String> = [
            "patternProperties", "unevaluatedProperties", "propertyNames", "minProperties", "maxProperties",
            "unevaluatedItems", "contains", "minContains", "maxContains", "uniqueItems", "allOf", "oneOf", "not",
            "dependentRequired", "dependentSchemas", "if", "then", "else", "x-guidance",
        ]
        guard unsupported.isDisjoint(with: schema.keys) else { throw invalid("Unsupported schema keyword") }
        for key in ["title", "description"] where schema[key] != nil {
            guard schema[key]?.stringValue != nil else { throw invalid("Schema metadata must be text") }
        }
        if let examples = schema["examples"], examples.arrayValue == nil { throw invalid("Examples must be an array") }
        for key in ["$defs", "definitions"] {
            if let value = schema[key] {
                guard let definitions = value.objectValue else { throw invalid("Definitions must be an object") }
                schema[key] = .object(try definitions.mapValues { try normalize($0, root: root) })
            }
        }
        if let reference = schema["$ref"] {
            guard let ref = reference.stringValue, schema.count == 1 else { throw invalid("Invalid schema reference") }
            if ref != "#" {
                let parts = ref.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count == 3, parts[0] == "#", ["$defs", "definitions"].contains(String(parts[1])),
                    !parts[2].isEmpty, root[String(parts[1])]?[String(parts[2])]?.objectValue != nil
                else {
                    throw invalid("Only resolved local definitions are supported")
                }
            }
            return .object(schema)
        }
        if let variants = schema["anyOf"] {
            let structural = [
                "type", "properties", "required", "additionalProperties", "items", "prefixItems", "enum", "const",
            ]
            guard structural.allSatisfy({ schema[$0] == nil }), let list = variants.arrayValue, !list.isEmpty else {
                throw invalid("Invalid anyOf schema")
            }
            schema["anyOf"] = .array(try list.map { try normalize($0, root: root) })
            return .object(schema)
        }
        let kind: String
        let nullable: Bool
        if let text = schema["type"]?.stringValue {
            kind = text
            nullable = false
        } else if let pair = schema["type"]?.arrayValue, pair.count == 2, pair.contains("null"),
            let other = pair.first(where: { $0 != "null" })?.stringValue
        {
            kind = other
            nullable = true
        } else {
            throw invalid("A supported type or nullable pair is required")
        }
        switch kind {
        case "object":
            if let additional = schema["additionalProperties"], additional != false {
                throw invalid("additionalProperties must be false")
            }
            guard let properties = (schema["properties"] ?? [:]).objectValue else {
                throw invalid("Invalid properties")
            }
            guard properties.keys.allSatisfy({ !$0.contains("\"") && !$0.contains("\n") }) else {
                throw invalid("Invalid property name")
            }
            schema["properties"] = .object(try properties.mapValues { try normalize($0, root: root) })
            schema["additionalProperties"] = false
            schema["required"] = .array(properties.keys.sorted().map(JSONValue.string))
        case "array":
            guard let items = schema["items"] else { throw invalid("Array items must be one schema") }
            schema["items"] = try normalize(items, root: root)
            if let prefix = schema["prefixItems"] {
                guard let list = prefix.arrayValue else { throw invalid("Invalid prefixItems") }
                schema["prefixItems"] = .array(try list.map { try normalize($0, root: root) })
            }
        case "string":
            if let format = schema["format"] {
                let supported = [
                    "", "date-time", "time", "date", "duration", "email", "hostname", "ipv4", "ipv6", "uuid",
                ]
                guard let text = format.stringValue, supported.contains(text) else {
                    throw invalid("Unsupported format")
                }
            }
        case "number", "integer", "boolean", "null": break
        default: throw invalid("Unsupported type")
        }
        for key in ["properties", "required", "additionalProperties", "items"] where schema[key] != nil {
            guard (kind == "object" && key != "items") || (kind == "array" && key == "items") else {
                throw invalid("Schema keyword does not apply to this type")
            }
        }
        if let value = schema["const"], !literal(value, kind: kind, nullable: nullable) {
            throw invalid("Invalid const")
        }
        if let value = schema["enum"] {
            guard let values = value.arrayValue, !values.isEmpty,
                values.allSatisfy({ literal($0, kind: kind, nullable: nullable) })
            else { throw invalid("Invalid enum") }
        }
        return .object(schema)
    }

    private static func literal(_ value: JSONValue, kind: String, nullable: Bool) -> Bool {
        switch value {
        case .null: return kind == "null" || nullable
        case .string(let text): return kind == "string" && !text.contains("\"") && !text.contains("\n")
        case .bool: return kind == "boolean"
        case .integer: return kind == "integer" || kind == "number"
        case .rawNumber(let number): return kind == "number" || (kind == "integer" && number.isInteger)
        case .number(let number):
            return number.isFinite && (kind == "number" || (kind == "integer" && number.rounded() == number))
        default: return false
        }
    }

    private static func invalid(_ message: String) -> OpenAIClientError {
        .invalidConfiguration("Agent output schema: " + message)
    }
}
