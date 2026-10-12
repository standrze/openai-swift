import Foundation
import HTTPTypes
import OpenAI
import OpenAIAPI
import OpenAPIRuntime
import XCTest

final class ModelParityTests: XCTestCase, @unchecked Sendable {
    func testRecursiveModelsForwardMetadataAndOverridesThroughCopyOnWriteStorage() throws {
        var value = try OpenAIJSON.decode(
            Components.Schemas.CompoundFilter.self, from: Data(#"{"type":"and","filters":[],"future":true}"#.utf8))
        XCTAssertEqual(value.jsonMetadata.field("type").rawString, #""and""#)
        XCTAssertEqual(value.jsonMetadata.extraFields["future"]?.rawString, "true")
        value.jsonOverrides["filters"] = .omitted
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        XCTAssertNil(encoded["filters"])
        XCTAssertEqual(encoded["type"], "and")
    }

    func testIntegerEnumPreservesFutureRawValues() throws {
        let value = try JSONDecoder().decode(
            Components.Schemas.LiveSessionAudioFormatPCMParam.RatePayload.self, from: Data("48000".utf8))
        XCTAssertEqual(value.rawValue, 48000)
        XCTAssertFalse(value.isKnown)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(value), as: UTF8.self), "48000")
    }

    func testFutureEnumValuesRoundTrip() throws {
        let value = try JSONDecoder().decode(
            Components.Schemas.Model.ObjectPayload.self, from: Data(#""future_model""#.utf8))
        XCTAssertEqual(value.rawValue, "future_model")
        XCTAssertFalse(value.isKnown)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(value), as: UTF8.self), #""future_model""#)
        XCTAssertEqual(Components.Schemas.Model.ObjectPayload.allCases, [.model])
    }

    func testMalformedMissingNullAndUnknownFields() throws {
        let data = Data(
            #"{"id":"m","created":"invalid","object":"future","owned_by":null,"shutdown_date":42,"future":9007199254740993123456}"#
                .utf8)
        let value = try OpenAIJSON.decode(Components.Schemas.Model.self, from: data)
        XCTAssertEqual(value.created, 0)
        XCTAssertEqual(value.ownedBy, "")
        XCTAssertNil(value.shutdownDate)
        XCTAssertEqual(value.jsonMetadata.field("created").presence, .invalid)
        XCTAssertEqual(value.jsonMetadata.field("created").rawString, #""invalid""#)
        XCTAssertEqual(value.jsonMetadata.field("owned_by").presence, .null)
        XCTAssertEqual(value.jsonMetadata.field("shutdown_date").presence, .invalid)
        XCTAssertEqual(value.jsonMetadata.field("absent").presence, .missing)
        XCTAssertEqual(value.jsonMetadata.extraFields["future"]?.rawString, "9007199254740993123456")
        let missing = try OpenAIJSON.decode(Components.Schemas.Model.self, from: Data("{}".utf8))
        XCTAssertEqual(missing.id, "")
        XCTAssertEqual(missing.jsonMetadata.field("id").presence, .missing)
    }

    func testGeneratedTransportPreservesNestedRawJSON() async throws {
        let transport = ModelTransport(
            #"{"object":"list","data":[{"id":"m","created":2,"object":"model","owned_by":"local","future":1e+999}]}"#)
        let client = try Client(openAIConfiguration: .ollama(), transport: transport)
        let result = try await client.listModels(.init())
        let model = try XCTUnwrap(result.ok.body.json.data.first)
        XCTAssertEqual(model.jsonMetadata.extraFields["future"]?.rawString, "1e+999")
        XCTAssertEqual(model.jsonMetadata.field("created").rawString, "2")
    }

    func testKnownDiscriminatorUsesWireValue() throws {
        let data = Data(#"{"role":"user","content":"hello"}"#.utf8)
        let message = try OpenAIJSON.decode(Components.Schemas.ChatCompletionRequestMessage.self, from: data)
        guard case .user(let user) = message else {
            return XCTFail("Expected typed user message")
        }
        XCTAssertEqual(user.role.rawValue, "user")
    }

    func testUnknownUnionVariantPreservesRawJSON() throws {
        let data = Data(#"{"role":"future_role","vendor":{"number":1e+999}}"#.utf8)
        let message = try OpenAIJSON.decode(Components.Schemas.ChatCompletionRequestMessage.self, from: data)
        guard case .undocumented(let raw) = message else { return XCTFail("Expected unknown variant") }
        XCTAssertEqual(raw.data, data)
        XCTAssertEqual(try raw.document.field(at: [.key("vendor"), .key("number")]).rawString, "1e+999")
        let primitive = try OpenAIJSON.decode(
            Components.Schemas.ChatCompletionRequestMessage.self, from: Data("true".utf8))
        guard case .undocumented(let rawPrimitive) = primitive else { return XCTFail("Expected raw primitive") }
        XCTAssertEqual(rawPrimitive.rawJSON, "true")
    }

    func testAnyOfUnknownEventAndKnownEventSelection() throws {
        let unknown = try OpenAIJSON.decode(
            Components.Schemas.ResponseStreamEvent.self,
            from: Data(#"{"type":"response.future","sequence_number":3,"future":true}"#.utf8))
        XCTAssertNotNil(unknown.undocumented)
        XCTAssertNil(unknown.value1)
        let known = try OpenAIJSON.decode(
            Components.Schemas.ResponseStreamEvent.self,
            from: Data(
                #"{"type":"response.output_text.delta","sequence_number":3,"item_id":"i","output_index":0,"content_index":0,"delta":"hi","logprobs":[]}"#
                    .utf8))
        XCTAssertNil(known.undocumented)
        XCTAssertEqual(known.value39?.delta, "hi")
        XCTAssertNil(known.value1)
    }

    func testModelOverridesOmitNullReplaceAndAddWithoutMetadata() throws {
        var model = Components.Schemas.Model(id: "typed", created: 1, object: .model, ownedBy: "local")
        model.jsonOverrides = [
            "id": .omitted, "created": .null, "owned_by": .value(["vendor": true]), "future": .value([1, 2]),
        ]
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(model))
        XCTAssertNil(encoded["id"])
        XCTAssertEqual(encoded["created"], .null)
        XCTAssertEqual(encoded["owned_by"], ["vendor": true])
        XCTAssertEqual(encoded["future"], [1, 2])
        XCTAssertNil(encoded["jsonMetadata"])
        XCTAssertNil(encoded["jsonOverrides"])
    }
}

private struct ModelTransport: ClientTransport {
    let json: String
    init(_ json: String) { self.json = json }
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (
        HTTPTypes.HTTPResponse, HTTPBody?
    ) {
        (HTTPTypes.HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(json))
    }
}
