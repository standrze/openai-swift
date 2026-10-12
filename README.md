# OpenAI for Swift

An async Swift library for OpenAI-compatible APIs, including Ollama. It uses the resource-service structure of [openai-go](https://github.com/openai/openai-go), with Swift `Codable`, `Sendable`, `async`/`await`, and `AsyncSequence` APIs. It uses Apple's maintained OpenAPI runtime and Swift Crypto, WebSocketKit/NIO on Linux, and an isolated optional AWS integration.

The library combines typed inference and media APIs with schema-flexible resources, a complete named REST catalog for a pinned Go SDK revision, Responses and Realtime WebSockets, webhook verification, and OAuth token acquisition. See [endpoint coverage](Documentation/EndpointCoverage.md) and [compatibility](Documentation/Compatibility.md) for the precise scope and validation status.

## Installation

Requires Swift 6.2 or later. Add the repository to your application's `Package.swift`:

```swift
.package(url: "https://github.com/standrze/openai-swift.git", branch: "main")
```

Add the product to your target dependencies:

```swift
.product(name: "OpenAI", package: "openai-swift")
```

The package declares macOS 13, iOS 16, tvOS 16, and watchOS 9 minimum versions. The complete dependency graph and generated module build for those Apple minimums. macOS fixture tests use Swift 6.4; Linux fixture validation is recorded in [verification](Documentation/Verification.md). Device runtimes and live provider accounts are separate validation steps.

## Full-schema API and advanced integrations

Add `OpenAIAPI` for generated request/response models and all 359 official-schema operations. See [generated API](Documentation/GeneratedAPI.md) for typed calls, streaming file uploads, provenance, and remaining Go differences. [Providers](Documentation/Providers.md) covers Azure, the separate `Integrations/Bedrock` package, cloud subject tokens, and native client certificates.

The facade also supports deep JSON mutations, omitted/null/override parameters, ordered middleware, safe diagnostic callbacks, typed results with raw response metadata, detailed Responses accumulation, and managed WebSocket lanes with explicit recovery. See the [pinned Go parity matrix](Documentation/Parity.md) for feature coverage and explicit native Swift/platform differences.

[Workflow helpers](Documentation/Helpers.md) cover polling and vector-store uploads, chat completion boundaries, hosted Agents streaming, local tool handlers, typed output, file preparation, and artifact downloads. They follow the pinned Go helper contracts using Swift concurrency and value types.

## Ollama chat and streaming

Use the name of a model already available on your Ollama server. The local configuration uses `http://localhost:11434/v1` and does not inherit `OPENAI_API_KEY`. Ollama documents its supported endpoints and parameters in its [OpenAI compatibility guide](https://docs.ollama.com/api/openai-compatibility).

```swift
import OpenAI

func chat(model: String) async throws {
    let client = OpenAIClient(configuration: .ollama())
    let request = ChatCompletionRequest(
        model: model,
        messages: [.system("Be concise."), .user("Explain Swift actors.")]
    )
    let completion = try await client.chat.completions.create(request)
    print(completion.choices.first?.message.text ?? "")
}
```

```swift
import OpenAI

func streamChat(model: String) async throws {
    let client = OpenAIClient(configuration: .ollama())
    let request = ChatCompletionRequest(model: model, messages: [.user("Write a short story.")])
    let stream = try await client.chat.completions.stream(request)
    defer { stream.cancel() }
    var accumulator = ChatCompletionAccumulator()
    for try await chunk in stream {
        accumulator.add(chunk)
        for choice in chunk.choices {
            if let text = choice.delta.content { print(text, terminator: "") }
        }
    }
    print()
    print("Tokens:", accumulator.completion?.usage?.totalTokens ?? 0)
}
```

Streams have one consumer. Keep `defer { stream.cancel() }` so early returns and loop breaks close the connection. Task cancellation also cancels the connection. Request `ChatStreamOptions(includeUsage: true)` when the provider supports final usage events.

[The Ollama example](Examples/Sources/OllamaChat/main.swift) is a separate executable package outside the library targets. From this package root:

```sh
swift run --package-path Examples ollama-chat [model] [prompt]
swift run --package-path Examples ollama-chat llama3.2 "Explain Swift actors" --stream
```

The first command shows optional positional arguments; omit the square-bracket placeholders when running it. Defaults are model `llama3.2` and a short Swift concurrency prompt. The chosen model must already be installed. `OLLAMA_BASE_URL` overrides the local URL. Completed and streaming calls were verified against real `gpt-oss:latest` inference on Ollama 0.31.1. See [live Ollama verification](Documentation/LiveOllama.md) for the 21 inference-suite checks, six follow-up model-route checks on 0.35.1, and the repeatable runner.

## Tools and structured output

Tool execution belongs to the application. The library sends schemas, decodes calls, and supplies `.tool(_:toolCallID:)` messages for results.

```swift
import OpenAI

func toolRequest(model: String) -> ChatCompletionRequest {
    let parameters: JSONValue = [
        "type": "object",
        "properties": ["city": ["type": "string"]],
        "required": ["city"],
        "additionalProperties": false,
    ]
    return ChatCompletionRequest(
        model: model,
        messages: [.user("What is the weather in Ashburn?")],
        tools: [.function(.init(name: "weather", parameters: parameters, strict: true))],
        toolChoice: .auto
    )
}
```

A completed call's `function.decodeArguments(as:)` decodes its JSON argument string into your `Decodable` type. Streaming arguments can be incomplete until their choice finishes; the accumulator joins fragments by choice and tool index. Use `.disabled` to disable tool use, avoiding the optional-argument ambiguity of `.none`.

For structured output, set `responseFormat` to `.jsonObject` or `.jsonSchema(ChatJSONSchema(name: "result", schema: schema, strict: true))`. Model and provider support determines which schema constraints apply. Multimodal message parts support text, image URLs/data URLs, input audio, files, refusal, and custom JSON.

## Responses, embeddings, and files

These examples use the hosted client, which reads `OPENAI_API_KEY`, `OPENAI_BASE_URL`, `OPENAI_ORG_ID`, and `OPENAI_PROJECT_ID` by default. Substitute a compatible base URL and model where supported. `.ollama()` explicitly omits cloud credentials and organization/project defaults.

```swift
import OpenAI

func response(model: String) async throws -> String {
    let client = OpenAIClient()
    let result = try await client.responses.create(
        ResponseRequest(model: model, input: "Explain structured concurrency.")
    )
    return result.outputText
}
```

`client.responses.stream` returns events with `type`, `textDelta`, and `rawValue`; apply the same explicit stream cancellation pattern. Responses input items and tool definitions accept `JSONValue`, with helpers on `ResponseInput`.

`ResponseAccumulator` joins streamed text and function arguments by output/content index. Feed each event to `try accumulator.add(event)` and inspect `accumulator.snapshot` when needed. Done events replace provisional values; terminal server output is authoritative. The snapshot keeps `terminalEvent` and the optional final server `response` separate from accumulated output, so partial, failed, and completed results remain distinguishable.

```swift
import Foundation
import OpenAI

func embedAndUpload(embeddingModel: String) async throws {
    let client = OpenAIClient()
    let result = try await client.embeddings.create(
        EmbeddingRequest(model: embeddingModel, input: .texts(["Swift actors", "Task groups"]))
    )
    let vectors = result.data.compactMap { $0.embedding.floats }
    print("Vectors:", vectors.count)

    let file = try await client.files.upload(
        filename: "notes.txt",
        data: Data("A short note about Swift.".utf8),
        purpose: "assistants",
        contentType: "text/plain"
    )
    print(file.id)
}
```

Uploads hold multipart bytes in memory so requests can be retried. Choose an upload purpose accepted by your provider and application.

Image and audio SSE APIs are available through `images.stream`, `images.streamEdit`, `audio.speechStream`, and `audio.transcribeStream`. Their events are `JSONValue` so provider event schemas remain intact; use the same cancellation pattern as chat streams. For lower-level multipart requests, `client.uploadResponse` accepts an ordered `[MultipartField]` to preserve repeated names such as `timestamp_granularities[]`. `client.uploadStream` opens multipart SSE operations. These methods still require endpoint and model support on the server.

## Provider extensions and raw REST

`RequestOptions` overrides the base URL, headers, query parameters, deadlines, retry count/delay, and JSON body fields. Ordered `headerMutations` and `queryMutations` support set/add/delete; `bodyOverride` replaces the complete body with an explicit MIME type. `queryItems` preserves repeated query names. Explicit `.null` sends JSON null; omitted optional Swift properties are absent. An extra body field replaces the same typed field. The typed `create` and `stream` methods always enforce their respective `stream` boolean.

```swift
import OpenAI

func providerRequest(model: String, client: OpenAIClient) async throws -> ChatCompletion {
    try await client.chat.completions.create(
        ChatCompletionRequest(model: model, messages: [.user("Hello")]),
        options: RequestOptions(
            extraBody: ["temperature": 0.2, "user": .null, "vendor_option": ["enabled": true]],
            maxRetries: 0
        )
    )
}
```

`client.resource("some_resource")` provides JSON create/retrieve/update/delete/list/action operations and lazy pagination through `all()`. Pagination recognizes identifier cursors and opaque `next`/`next_page` tokens; `PaginationStyle` selects a specific endpoint's convention when needed. `client.send`, `download`, `upload`, and `stream` accept application-owned types or raw bytes for additional endpoints. Paths are relative to the configured API prefix; escape identifiers with `OpenAIClient.pathComponent` when building paths yourself. The library does not translate Ollama's native `/api` protocol.

Every operation listed by the pinned upstream API references has a named `RESTEndpoint` descriptor. Descriptors bind and escape path arguments, apply API version defaults, and dispatch through the same client. This also covers organization administration and evolving APIs whose bodies use `JSONValue`:

```swift
import OpenAI

func project(id: String, client: OpenAIClient) async throws -> JSONValue {
    try await client.api.call(
        .adminOrganizationProjectsRetrieve,
        parameters: ["project_id": id]
    )
}
```

Use `client.api.decode` for your own `Decodable` result, `response` for original bytes and headers, `upload` for multipart, `stream` for SSE, or `bytes` for incremental binary data. Named services provide additional helpers for uploads, threads, vector stores, fine-tuning, containers, evals, skills, videos, conversations, agents/vaults, ChatKit, Live, safety, decisions, provenance, and webhook configuration. Beta version headers and query parameters are inherited by nested resources and remain overridable.

## WebSockets, webhooks, and OAuth

Responses WebSockets support persistent connections and sequential response turns. Realtime uses the same JSON connection for its event protocol. Each connection has one receiving consumer and optional message limits; operations never automatically reconnect or replay messages.

```swift
import OpenAI

func socketResponse(model: String, client: OpenAIClient) async throws -> String {
    let connection = try await client.responses.connect()
    do {
        try await connection.createResponse(ResponseRequest(model: model, input: "Hello"))
        let response = try await connection.finalResponse()
        await connection.close()
        return response.outputText
    } catch {
        await connection.close()
        throw error
    }
}
```

`client.realtime.connect(model:)` sends and receives `JSONValue` events; `client.realtime.createCall(sdp:session:)` returns the SDP answer and location header for application-owned WebRTC media. `WebhookVerifier` verifies original HTTP body bytes, signatures, and replay timestamps before decoding an event. `OAuthTokenProvider` caches client-credentials, RFC 8693, or OpenAI workload-identity tokens with shared refresh, and `ClientConfiguration.accessTokenProvider` supplies dynamic bearer authentication. Explicit Authorization headers take precedence. See [protocol and authentication examples](Documentation/Protocols.md).

## Reliability and testing

Defaults are two retries after the first attempt and no SDK timeout. A positive `timeout` sets an attempt deadline; `RequestOptions.deadline` bounds the whole operation, including authentication, retry waits, and the body. Selected network failures, HTTP 408/409/429, and server errors are retried with bounded backoff; retry headers are honored. Once streaming headers succeed, the stream is never replayed. Set `maxRetries: 0` for operations your application must not replay. `APIError` retains status, headers, response bytes, and request ID; `OpenAIClientError` describes local decoding, pagination, configuration, and stream failures.

Supply any `OpenAITransport` to `OpenAIClient(configuration:transport:)` to record requests, return fixtures, or use another HTTP implementation. The included `URLSessionTransport` handles real HTTP. [Architecture](Documentation/Architecture.md) documents transport ownership, buffering limits, and a fixture example.

From this directory:

```sh
swift build
swift test
sh scripts/check-format.sh
```

Tests cover model wire formats, every catalog route, request construction, retries, multipart bodies, fragmented SSE, WebSockets, OAuth refresh, webhook signatures, cancellation, pagination, and local HTTP/WebSocket fixtures. The [verification record](Documentation/Verification.md) separates regression checks from [real Ollama inference](Documentation/LiveOllama.md), including tools, structured output, embeddings, and vision. Hosted OpenAI calls remain untested. See [CONTRIBUTING.md](CONTRIBUTING.md).

To exercise the example against a temporary local fixture after building it:

```sh
swift build --package-path Examples
python3 scripts/smoke-example.py "$(swift build --package-path Examples --show-bin-path)/ollama-chat"
```
