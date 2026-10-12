import Foundation
import OpenAI

extension LiveSuite {
    private var tool: ChatTool {
        .function(
            .init(
                name: "temperature", description: "Get the temperature for a city.",
                parameters: [
                    "type": "object", "properties": ["city": ["type": "string"]],
                    "required": ["city"], "additionalProperties": false,
                ]))
    }

    private func toolRequest() -> ChatCompletionRequest {
        var request = chatRequest("Use temperature for Ashburn. After receiving the result, report its temperature.")
        request.tools = [tool]
        request.toolChoice = .function("temperature")
        return request
    }

    private func validateTool(_ message: ChatMessage) throws -> ChatToolCall {
        guard let call = message.toolCalls?.first else { throw LiveFailure("Model returned no function call") }
        try require(call.function.name == "temperature", "Function name differs")
        try require(!call.id.isEmpty, "Function call ID is missing")
        let arguments = try call.function.decodeArguments(as: JSONValue.self)
        try require(arguments["city"]?.stringValue?.lowercased() == "ashburn", "Function arguments differ")
        return call
    }

    func runTools() async {
        await check("chat.tools/replay") {
            let request = toolRequest()
            let response = try await client.chat.completions.create(request)
            guard let message = response.choices.first?.message else { throw LiveFailure("Missing assistant message") }
            let call = try validateTool(message)
            var continuation = chatRequest("unused")
            continuation.messages =
                request.messages + [message.asAssistantMessage(), .tool("{\"temperature\":72}", toolCallID: call.id)]
            let result = try await client.chat.completions.create(continuation)
            let text = result.choices.first?.message.text ?? ""
            try require(text.contains("72"), "Tool result was not reflected in the continuation")
            return "\(call.function.name)(\(call.function.arguments)); \(text)"
        }
        await check("chat.tools/stream") {
            let stream = try await client.chat.completions.stream(toolRequest())
            defer { stream.cancel() }
            var accumulator = ChatCompletionAccumulator()
            for try await chunk in stream {
                try require(accumulator.add(chunk), "Tool accumulator rejected chunk")
            }
            guard let message = accumulator.completion?.choices.first?.message else {
                throw LiveFailure("Missing accumulated tool message")
            }
            let call = try validateTool(message)
            return "\(call.function.name)(\(call.function.arguments))"
        }
        await check("responses.tools/replay") {
            var request = responseRequest("Use temperature for Ashburn. After its result, report the temperature.")
            request.tools = [
                ResponseInput.functionTool(
                    name: "temperature",
                    parameters: [
                        "type": "object", "properties": ["city": ["type": "string"]], "required": ["city"],
                    ])
            ]
            request.toolChoice = ["type": "function", "name": "temperature"]
            let response = try await client.responses.create(request)
            guard let call = response.functionCalls.first else { throw LiveFailure("Missing Responses function call") }
            try require(call.name == "temperature" && !call.callID.isEmpty, "Responses function identity differs")
            let arguments = try OpenAIJSON.decode(JSONValue.self, from: Data(call.arguments.utf8))
            try require(
                arguments["city"]?.stringValue?.lowercased() == "ashburn", "Responses function arguments differ")
            var continuation = responseRequest("unused")
            continuation.input = .items(
                [ResponseInput.message("Get the temperature in Ashburn and report the result.")]
                    + response.output.map(\.rawValue)
                    + [ResponseInput.functionResult(callID: call.callID, output: "{\"temperature\":72}")])
            let result = try await client.responses.create(continuation)
            try require(result.outputText.contains("72"), "Responses tool result was not reflected in continuation")
            return result.outputText
        }
    }
}
