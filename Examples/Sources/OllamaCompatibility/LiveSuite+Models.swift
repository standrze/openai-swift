import Foundation
import OpenAI

extension LiveSuite {
    func runModelRetrieval() async {
        await check("server/version") {
            let apiURL = configuration.baseURL.deletingLastPathComponent().appendingPathComponent("api")
            let native = OpenAIClient(configuration: .ollama(baseURL: apiURL))
            let version: JSONValue = try await native.send(.get, path: "version")
            serverVersion = version["version"]?.stringValue
            try require(serverVersion != nil, "Ollama did not return its version")
            return serverVersion ?? ""
        }
        await check("models.list/retrieve") {
            let models = try await client.models.list()
            try require(models.data.contains { $0.id == model }, "Selected model is absent from /v1/models")
            try require(models.data.contains { $0.id.contains("/") }, "Install a namespaced model to test this route")
            for entry in models.data {
                let retrieved = try await client.models.retrieve(entry.id)
                try require(retrieved.id == entry.id, "Retrieved model differs from requested ID")
            }
            return "Listed and retrieved \(models.data.count) models, including namespaced IDs"
        }
        await check("models/raw-rest") {
            let models = try await client.models.list()
            for entry in models.data {
                let path = "models/" + OpenAIClient.pathComponent(entry.id)
                let response = try await client.request(.get, path: path)
                let value = try OpenAIJSON.decode(JSONValue.self, from: response.data)
                try require(value["id"]?.stringValue == entry.id, "Raw REST model differs")
                let downloaded = try await client.download(path: path)
                let model = try OpenAIJSON.decode(OpenAIModel.self, from: downloaded.data)
                try require(model.id == entry.id, "Downloaded model differs")
            }
            return "Raw request and download retrieved all \(models.data.count) model IDs"
        }
        await check("models/raw-stream") {
            let models = try await client.models.list()
            for entry in models.data {
                let response = try await client.streamBytes(path: "models/" + OpenAIClient.pathComponent(entry.id))
                defer { response.cancel() }
                var data = Data()
                for try await chunk in response.body { data.append(chunk) }
                let model = try OpenAIJSON.decode(OpenAIModel.self, from: data)
                try require(model.id == entry.id, "Streamed raw model differs")
            }
            return "Streamed raw retrieval decoded all \(models.data.count) model IDs"
        }
        await check("models/fallback-controls") {
            let models = try await client.models.list()
            guard let namespaced = models.data.first(where: { $0.id.contains("/") }) else {
                throw LiveFailure("Missing namespaced model")
            }
            var literalConfiguration = configuration
            literalConfiguration.modelRetrievalFallback = false
            for (candidate, id) in [
                (client.reconfigured(literalConfiguration), namespaced.id),
                (client, "swift-sdk-missing-namespace/\(UUID().uuidString):latest"),
            ] {
                do {
                    _ = try await candidate.request(.get, path: "models/" + OpenAIClient.pathComponent(id))
                    throw LiveFailure("Expected model 404")
                } catch let error as APIError {
                    try require(error.statusCode == 404, "Original model 404 was not preserved")
                }
            }
            return "Disabled workaround and unknown namespaced ID both retain Ollama's 404"
        }
    }
}
