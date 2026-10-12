import Foundation
import OpenAI

extension LiveSuite {
    func runInference() async {
        await check("chat.create") {
            let response = try await client.chat.completions.create(chatRequest("Reply with SWIFT_OK."))
            try require(!(response.choices.first?.message.text ?? "").isEmpty, "Chat text is empty")
            try require((response.usage?.totalTokens ?? 0) > 0, "Chat usage is missing")
            return response.choices.first?.message.text ?? ""
        }
        await check("chat/reasoning-fields") {
            let request = chatRequest("What is 2 plus 2? Reply briefly.")
            let result = try await client.withResponse { scoped in
                try await scoped.chat.completions.create(request)
            }
            let raw = try OpenAIJSON.decode(JSONValue.self, from: result.response.data)
            guard let message = result.value.choices.first?.message else { throw LiveFailure("Missing chat message") }
            let projected = try JSONValue.encode(message)
            var fields = 0
            for key in ["reasoning", "reasoning_content"] {
                if let value = raw["choices"]?[0]?["message"]?[key] {
                    try require(projected[key] == value, "Chat decoding dropped the server's \(key) field")
                    fields += 1
                }
            }
            return "\(fields) server reasoning fields retained"
        }
        await check("chat.stream/usage/accumulator") {
            var request = chatRequest("Count from one to five in words.")
            request.streamOptions = .init(includeUsage: true)
            let stream = try await client.chat.completions.stream(request)
            defer { stream.cancel() }
            var accumulator = ChatCompletionAccumulator()
            var text = ""
            var chunks = 0
            var reasoning = ""
            for try await chunk in stream {
                try require(accumulator.add(chunk), "Accumulator rejected a real chat chunk")
                text += chunk.choices.first?.delta.content ?? ""
                reasoning += chunk.choices.first?.delta.reasoning ?? ""
                chunks += 1
            }
            try require(!text.isEmpty, "Stream text is empty")
            try require(accumulator.completion?.choices.first?.message.text == text, "Stream accumulation differs")
            try require(
                (accumulator.completion?.choices.first?.message.reasoning ?? "") == reasoning,
                "Reasoning accumulation differs")
            try require((accumulator.completion?.usage?.totalTokens ?? 0) > 0, "Streaming usage is missing")
            return "\(chunks) chunks; \(text)"
        }
        await check("chat.stream/cancellation") {
            let stream = try await client.chat.completions.stream(chatRequest("Count from one to a thousand."))
            defer { stream.cancel() }
            var iterator = stream.makeAsyncIterator()
            try require(try await iterator.next() != nil, "Stream ended before cancellation")
            stream.cancel()
            let response = try await client.models.list()
            try require(!response.data.isEmpty, "Client is unusable after stream cancellation")
            return "Cancelled an active generation; subsequent request succeeded"
        }
        await check("completions.create/stream") {
            let request = CompletionRequest(
                model: model, prompt: "The capital of France is", maxTokens: 256, temperature: 0)
            let response = try await client.completions.create(request)
            try require(!(response.choices.first?.text ?? "").isEmpty, "Completion text is empty")
            let stream = try await client.completions.stream(request)
            defer { stream.cancel() }
            var text = ""
            for try await event in stream { text += event.choices.first?.text ?? "" }
            try require(!text.isEmpty, "Completion stream is empty")
            return text
        }
        await check("responses.create") {
            let response = try await client.responses.create(responseRequest("Reply with SWIFT_RESPONSE_OK."))
            try require(response.status == "completed", "Responses status is \(response.status ?? "missing")")
            try require(!response.outputText.isEmpty, "Responses output text is empty")
            try require((response.usage?.totalTokens ?? 0) > 0, "Responses usage is missing")
            return response.outputText
        }
        await check("responses.stream/accumulator") {
            let stream = try await client.responses.stream(responseRequest("Say hello in five words."))
            defer { stream.cancel() }
            var accumulator = ResponseAccumulator()
            var text = ""
            var events = 0
            for try await event in stream {
                try accumulator.add(event)
                text += event.textDelta ?? ""
                events += 1
            }
            let snapshot = accumulator.snapshot
            try require(snapshot.terminalEvent == "response.completed", "Responses stream did not complete")
            try require(!text.isEmpty && snapshot.outputText == text, "Responses accumulation differs from deltas")
            try require(snapshot.response?.outputText == text, "Final server response differs from streamed text")
            return "\(events) events; \(text)"
        }
        await check("structured-output/json-schema") {
            var request = chatRequest("Return a JSON object with status equal to ok and count equal to 3.")
            request.responseFormat = .jsonSchema(
                .init(
                    name: "live_check",
                    schema: [
                        "type": "object",
                        "properties": ["status": ["type": "string", "enum": ["ok"]], "count": ["type": "integer"]],
                        "required": ["status", "count"], "additionalProperties": false,
                    ], strict: true))
            let response = try await client.chat.completions.create(request)
            let data = Data((response.choices.first?.message.text ?? "").utf8)
            let object = try OpenAIJSON.decode(JSONValue.self, from: data)
            try require(object["status"] == "ok" && object["count"] == 3, "Structured output violates requested values")
            return String(decoding: data, as: UTF8.self)
        }
        await check("error/missing-model") {
            do {
                _ = try await client.chat.completions.create(
                    ChatCompletionRequest(model: "swift-sdk-nonexistent-model:missing", messages: [.user("Hello")]))
                throw LiveFailure("Missing model unexpectedly succeeded")
            } catch let error as APIError {
                try require(error.statusCode == 404, "Missing model returned \(error.statusCode), expected 404")
                return "HTTP \(error.statusCode) retained as APIError"
            }
        }
    }
}
