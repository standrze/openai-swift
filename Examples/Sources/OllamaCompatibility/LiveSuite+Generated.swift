import Foundation
import OpenAI
import OpenAIAPI

extension LiveSuite {
    func runGeneratedModels() async {
        await check("generated/models") {
            let generated = try OpenAIAPI.Client(openAIConfiguration: configuration)
            let response = try await generated.listModels(.init())
            let models = try response.ok.body.json.data
            try require(models.contains { $0.id == model }, "Generated models omit selected model")
            for entry in models {
                let retrieved = try await generated.retrieveModel(.init(path: .init(model: entry.id)))
                try require(try retrieved.ok.body.json.id == entry.id, "Generated model retrieval differs")
            }
            return "Listed and retrieved \(models.count) models with generated schemas, including namespaced IDs"
        }
    }

    func runGenerated() async {
        await runGeneratedModels()
        await check("generated/chat") {
            let generated = try OpenAIAPI.Client(openAIConfiguration: configuration)
            let body = try OpenAIJSON.decode(
                Components.Schemas.CreateChatCompletionRequest.self,
                from: JSONEncoder().encode(chatRequest("Reply with GENERATED_OK.")))
            let response = try await generated.createChatCompletion(.init(body: .json(body)))
            let decoded = try response.ok.body.json
            try require(!decoded.choices.isEmpty, "Generated chat choices are missing")
            let data = try JSONEncoder().encode(decoded)
            let projected = try OpenAIJSON.decode(ChatCompletion.self, from: data)
            try require(!(projected.choices.first?.message.text ?? "").isEmpty, "Generated chat text is empty")
            return projected.choices.first?.message.text ?? ""
        }
        await check("generated/responses") {
            let generated = try OpenAIAPI.Client(openAIConfiguration: configuration)
            let body = try OpenAIJSON.decode(
                Components.Schemas.CreateResponse.self,
                from: JSONEncoder().encode(responseRequest("Reply with GENERATED_RESPONSE_OK.")))
            let response = try await generated.createResponse(.init(body: .json(body)))
            let decoded = try response.ok.body.json
            let data = try JSONEncoder().encode(decoded)
            let projected = try OpenAIJSON.decode(Response.self, from: data)
            try require(!projected.outputText.isEmpty, "Generated Responses text is empty")
            return projected.outputText
        }
    }
}
