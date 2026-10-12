# Architecture

`OpenAIClient` is a `Sendable` value containing copied configuration and an injected `OpenAITransport`. Its service properties are small values that reuse the same client. The package exports the ergonomic `OpenAI` library and Apple-generated `OpenAIAPI` library. Swift Crypto owns HMAC/SHA-256. The separate Bedrock integration delegates signing and credential discovery to the AWS SDK. See [GeneratedAPI.md](GeneratedAPI.md) and [Providers.md](Providers.md).

## Requests and responses

Typed services encode `Codable` requests with explicit wire keys. `RequestOptions.extraBody` merges top-level JSON fields after encoding; JSON null is distinct from an omitted optional property. Services that create or stream completions override `stream` themselves. Multipart uploads use string fields and `MultipartFile`, rather than `extraBody`, and buffer their complete bodies in memory for replayable retries.

Multipart primitives also accept ordered `[MultipartField]` values for repeated field names. `uploadResponse` retains arbitrary response bytes; `uploadStream` decodes SSE after a multipart POST. Image generation/edit and audio speech/transcription stream services return `JSONValue` events to preserve their evolving schemas.

The client joins relative endpoint paths beneath the configured base URL. It rejects absolute paths, query/fragment injection, empty path segments, dot segments, and invalid configuration. Dynamic identifiers are escaped as individual components. Request options can override configured headers, timeout, retry count, and query parameters; ordered query items preserve repeated names. API keys become bearer authorization headers. An optional async token provider resolves authentication at operation start and again for retried attempts; explicit Authorization headers override both sources. `OAuthTokenProvider` implements cached client-credentials and token-exchange acquisition separately from request dispatch.

`send` decodes an application-owned response type. `download` retains raw bytes, status, and headers. `APIResource` uses `JSONValue`, with `Page` for lists. Lazy pagination recognizes identifier cursors and opaque `next`/`next_page` tokens, choosing `after` or `page` as required. `PaginationStyle` provides explicit cursor, conversation, next-cursor, token, and single-page policies. Missing or repeated continuation tokens fail instead of looping indefinitely; automatic mode stops after one page when compatible providers supply no continuation metadata. Typed list methods return one page; use their query options to request subsequent pages.

`RESTEndpoint` descriptors bind named identifiers to pinned upstream route templates. `RESTClient` dispatches the catalog through the same typed/raw/multipart/SSE primitives. API versions are request defaults; resource defaults propagate through nesting and merge case-insensitively with explicit header overrides. The checked-in JSON inventory generates small descriptor files grouped by API family, and a comparison script audits it against the official pinned API references.

## Streaming and cancellation

`URLSessionTransport` receives incremental data through a session delegate and returns an `HTTPStreamResponse` as soon as headers arrive. The transport owns the session task and exposes a cancellation closure. It bounds unread network chunks, defaulting to 64 chunks. Non-streaming downloads collect the complete response in memory. The client parses fragmented Server-Sent Events, decodes payloads, and exposes a single-consumer `OpenAIStream`.

Client defaults allow 256 buffered decoded events and 8 MiB per SSE event. A slow consumer or oversized event fails explicitly; events are not silently discarded. SSE comments, multiline data, LF/CRLF boundaries, `[DONE]`, error events, and premature known-protocol termination are handled at the stream layer. The parser does not require one network chunk per event or UTF-8 character.

The consumer should always install `defer { stream.cancel() }`, especially when it may stop early. Cancellation closes the HTTP connection and producer task. Normal completion also closes transport resources. Chat accumulation is separate from transport: `ChatCompletionAccumulator` merges indexed choices, tool-call fragments, reasoning, refusal, logprobs, and audio, and rejects chunks belonging to a different response ID. Accumulation does not execute tools or validate partially emitted JSON arguments.

`ResponseAccumulator` provides a sparse output/content projection for Responses streams. It joins text, refusal, and function arguments; done payloads replace provisional values, and final server output replaces the projection even when explicitly empty. Conflicting response IDs are rejected, conflicting item IDs start fresh, and `reset()` clears the stream state. Its snapshot exposes the terminal event and final server response separately: accumulated text alone does not establish completion.

`streamBytes` returns original incremental bytes and cancellation ownership without interpreting SSE. The WebSocket transport waits for a successful upgrade, uses native framing/TLS/control frames, enforces optional message limits and a handshake deadline, and closes on cancellation. Apple platforms use URLSession; Linux uses WebSocketKit/NIO. `OpenAIJSONConnection` pulls one message at a time and rejects overlapping receive calls. `finalResponse()` returns completed, failed, or incomplete server responses; inspect their status. Protocol error events retain their payload in the thrown error. Connections never reconnect automatically.

Webhook verification authenticates the original bytes before JSON decoding, with HMAC-SHA256 and timestamp tolerance. Swift Crypto supplies maintained cross-platform SHA-256/HMAC, checked with standard vectors and native CryptoKit fixtures. Verification does not persist webhook IDs, so applications must deduplicate deliveries themselves.

## Retries and errors

The default policy permits two retries after the original attempt. Selected transient URL errors, HTTP 408/409/429, and HTTP status codes at or above 500 qualify. `x-should-retry` can override status-based decisions. `retry-after-ms` and `Retry-After` are bounded by the configured maximum retry delay; otherwise exponential backoff includes jitter.

Streams can retry before successful response headers. A started stream is never replayed. Non-streaming operations, including POST and collected multipart requests, can be replayed; choose zero retries when your operation cannot safely be repeated. Ordinary requests do not generate idempotency keys; hosted Agents workflow helpers generate stable input/tool-result keys. The SDK timeout defaults to zero (unlimited); a positive timeout bounds each attempt. `RequestOptions.deadline` bounds the entire operation, including authentication, retry waits, and body consumption. Task cancellation interrupts requests and waits.

`APIError` retains server diagnostics and request IDs. `OpenAIClientError` distinguishes invalid paths/configuration, decode errors, stream limits/termination, and invalid pagination. Underlying transport errors remain available as their original error types.

## Injected transports

Implement both protocol operations. Custom implementations must return bytes incrementally from `stream`, keep buffering bounded, and make its cancellation closure release their resources. A fixture-only transport can intentionally reject streaming:

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenAI

struct ModelFixtureTransport: OpenAITransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        HTTPResponse(data: Data(#"{"object":"list","data":[]}"#.utf8), statusCode: 200)
    }

    func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
        throw URLError(.unsupportedURL)
    }
}

func fixtureClient() -> OpenAIClient {
    OpenAIClient(configuration: ClientConfiguration(apiKey: nil), transport: ModelFixtureTransport())
}
```

`Tests/OpenAITests` includes recording transports, model fixtures, and local HTTP integration checks. Tests distinguish these controlled checks from live provider inference; see [Compatibility.md](Compatibility.md).

## Request hooks and exact response metadata

Client and request middleware wrap each attempt in declaration order. `prepareAttempt` runs after middleware changes the serialized bytes, so signing sees the actual payload. Diagnostic callbacks receive method/path/status/attempt only; raw response observers are explicitly opt-in. Applications should keep their own callbacks free of credentials and private payload logging.

`withResponse` accepts one operation using its scoped client. `JSONDocument` tracks original byte spans, preserving decimal spellings, unknown fields, and missing/null/value states independently of typed models.

```swift
import OpenAI

func responseWithMetadata(client: OpenAIClient, model: String) async throws {
    var options = RequestOptions()
    options.jsonMutations = [
        .set([.key("metadata"), .key("application")], .string("example")),
        .delete([.key("temperature")])
    ]
    let result = try await client.withResponse { [options] scoped in
        try await scoped.responses.create(ResponseRequest(model: model, input: "Hello"), options: options)
    }
    print(result.value.id)
    print(result.response.header("x-request-id") ?? "")
    let document = try result.document
    print(document.field(at: [.key("usage"), .key("total_tokens")]).rawString ?? "missing")
}
```

Use `JSONParameter<T>` in application-owned `Encodable` types and encode it through the keyed-container overload to distinguish omission, explicit null, typed values, and arbitrary wire overrides. Generated models retain Apple's generated property representation; deep mutations provide the equivalent wire-level control without modifying generated source.

## Managed Responses sessions

`connectSession` owns one physical reader and serializes writes. The default lane receives untagged and unclaimed events. Explicit lane IDs use `stream_id` and require provider support for that extension. Each lane has one consumer; buffering is unlimited by default with optional shared event/byte and per-lane limits. Receive cancellation removes only that waiter. Closing a lane ends its consumer; reconnect invalidates every old lane and requires acquiring new lanes. Recovery can restore application state but does not replay requests with uncertain delivery. See [Protocols.md](Protocols.md) for routing, recovery, and native frame limits, and [Helpers.md](Helpers.md) for polling and hosted Agents workflows.

```swift
import OpenAI

func sessionResponse(client: OpenAIClient, model: String) async throws {
    let session = try await client.responses.connectSession()
    do {
        let lane = try await session.lane()
        try await lane.send(ResponseRequest(model: model, input: "Hello"))
        for try await event in lane.events {
            print(event.type)
            if ["response.completed", "response.failed", "response.incomplete"].contains(event.type) { break }
        }
        await session.close()
    } catch {
        await session.close()
        throw error
    }
}
```
