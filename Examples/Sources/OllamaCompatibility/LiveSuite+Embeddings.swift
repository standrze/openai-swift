import Foundation
import OpenAI
import OpenAIAPI

extension LiveSuite {
    func runEmbeddings(model: String) async {
        await check("embeddings/float-batch") {
            let response = try await client.embeddings.create(
                .init(model: model, input: .texts(["Swift actors", "Swift concurrency"]), encodingFormat: "float"))
            try require(response.data.count == 2, "Embedding batch count differs")
            let vectors = response.data.compactMap { $0.embedding.floats }
            try require(vectors.count == 2 && !vectors[0].isEmpty, "Embedding vectors are missing")
            try require(vectors[0].count == vectors[1].count, "Embedding dimensions differ within batch")
            try require(vectors.flatMap { $0 }.allSatisfy(\.isFinite), "Embedding contains nonfinite values")
            try require(response.data.map(\.index) == [0, 1], "Embedding indices differ")
            return "\(model): two \(vectors[0].count)-dimensional vectors"
        }
        await check("embeddings/base64") {
            let response = try await client.embeddings.create(
                .init(model: model, input: "Swift actors", encodingFormat: "base64"))
            guard let encoded = response.data.first?.embedding.base64, let data = Data(base64Encoded: encoded) else {
                throw LiveFailure("Embedding base64 is missing or invalid")
            }
            try require(!data.isEmpty && data.count % 4 == 0, "Embedding bytes are not float32 values")
            return "\(data.count / 4) base64-encoded float32 values"
        }
        await check("generated/embeddings") {
            let generated = try OpenAIAPI.Client(openAIConfiguration: configuration)
            let body = try OpenAIJSON.decode(
                Components.Schemas.CreateEmbeddingRequest.self,
                from: JSONEncoder().encode(EmbeddingRequest(model: model, input: "Swift", encodingFormat: "float")))
            let result = try await generated.createEmbedding(.init(body: .json(body)))
            let data = try JSONEncoder().encode(result.ok.body.json)
            let projected = try OpenAIJSON.decode(EmbeddingResponse.self, from: data)
            try require(!(projected.data.first?.embedding.floats ?? []).isEmpty, "Generated embedding is empty")
            return "Generated embedding decoded and projected"
        }
    }

    func runVision(model: String) async {
        await check("chat/vision") {
            // A 1x1 PNG fixture. The check verifies image transport and decoding, not visual reasoning accuracy.
            let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII="
            let request = ChatCompletionRequest(
                model: model,
                messages: [
                    .user(
                        .parts([
                            .text("Describe this image in one short sentence."),
                            .imageURL(.init(url: "data:image/png;base64," + png)),
                        ]))
                ],
                maxTokens: 256, reasoningEffort: "none")
            let result = try await client.chat.completions.create(request)
            let text = result.choices.first?.message.text ?? ""
            try require(!text.isEmpty, "Vision response is empty")
            return text
        }
    }
}
