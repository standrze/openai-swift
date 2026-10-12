import Foundation
import OpenAI
@_spi(Generated) import OpenAPIRuntime

extension OpenAPIObjectContainer: JSONDefaultValue {
    public static var jsonDefaultValue: Self { .init() }
}

extension OpenAPIValueContainer: JSONDefaultValue {
    public static var jsonDefaultValue: Self { nil }
}

extension OpenAPIArrayContainer: JSONDefaultValue {
    public static var jsonDefaultValue: Self { .init() }
}

extension Converter {
    /// Retains response JSON for generated nested-field metadata while preserving runtime date decoding.
    public func getOpenAIResponseBodyAsJSON<Value: Decodable, Output>(
        _ type: Value.Type, from body: HTTPBody?, transforming transform: (Value) -> Output
    ) async throws -> Output {
        guard let body else {
            return try await getResponseBodyAsJSON(type, from: nil, transforming: transform)
        }
        let data = try await Data(collecting: body, upTo: .max)
        return try await OpenAIJSON.$source.withValue(JSONDocument(data: data)) {
            try await getResponseBodyAsJSON(type, from: HTTPBody(data), transforming: transform)
        }
    }
}
