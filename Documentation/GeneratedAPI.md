# Generated API and SDK interoperability

`OpenAI` contains the ergonomic services, transport hooks, SSE/WebSocket sessions, and provider integrations. `OpenAIAPI` adds Apple's generated `Client`, `APIProtocol`, `Operations`, and `Components.Schemas`. The checked-in schema defines 359 operations and 2,048 original component schemas. It covers every normalized REST route in the pinned Go catalog. These counts describe source coverage, not live server support or identical Go runtime behavior.

```swift
import OpenAI
import OpenAIAPI

func generatedModels() async throws {
    let client = try OpenAIAPI.Client(openAIConfiguration: .ollama())
    let result = try await client.listModels(.init())
    for model in try result.ok.body.json.data {
        print(model.id)
    }
}
```

Generated operations expose their documented status cases, headers, content types, nested request/response models, unions, and multipart parts. Pass any `OpenAPIRuntime.ClientTransport` or middleware to integrate a different stack. The configured initializer applies authentication, timeout, bounded retry policy, query/body/header overrides, and rejects cross-origin redirects. Single-iteration bodies and all multipart uploads are not replayed: the serialized outer body cannot prove that every nested part is reusable. `RequestOptionsMiddleware` also works with a manually constructed generated client. URLRequest middleware and signing hooks belong to `OpenAIClient`; the generated initializer rejects them instead of silently ignoring them.

A response observer on a generated client receives original JSON bytes before typed decoding, bounded by `maxEventBytes`; non-JSON responses supply headers only. For an ergonomic typed service, `OpenAIClient.withResponse` returns `APIResult` containing the decoded value, response bytes/headers, and a `JSONDocument`. Its field API distinguishes missing/null/value and preserves exact numeric lexemes and unknown fields. It works with any generated schema used as an application-owned `send` result, too.

## Streaming file uploads

The generated multipart APIs use Apple's `HTTPBody` and `MultipartBody`. File bodies read bounded chunks, open a fresh handle for each iteration, detect growth/truncation, and close handles on completion, error, cancellation, or iterator release. Keep the file unchanged while uploading. Other asynchronous readers can supply `HTTPBody` directly; mark non-replayable sources with `.single`.

```swift
import Foundation
import OpenAIAPI
import OpenAPIRuntime

func uploadFile(client: OpenAIAPI.Client, url: URL) async throws {
    let parts: [Components.Schemas.CreateFileRequest] = [
        .file(.init(payload: .init(body: try HTTPBody(fileURL: url)), filename: url.lastPathComponent)),
        .purpose(.init(payload: .init(body: HTTPBody("assistants"))))
    ]
    _ = try await client.createFile(.init(body: .multipartForm(MultipartBody(parts))))
}
```

The `OpenAI` facade's existing `MultipartFile` remains an in-memory convenience. Use generated multipart APIs for uploads that must avoid a complete in-memory body.

## Reproduction and provenance

The official source, MIT license, commit, checksum, adaptation report, and generator diagnostics are under `Documentation/Reference`. The original schema remains unchanged. `Tools/Generator` pins Apple's generator independently of the library dependencies. Run `ruby scripts/regenerate-api.rb` to regenerate, or add `--check` to compare checked-in output. Generated files are excluded from hand-written source formatting.

The overlay handles generator limitations: standalone null alternatives, required-only object branches, negative type lists, a multipart voice alias, JSON/multipart model sharing, required properties missing schema definitions, and optional multipart request bodies. Missing property definitions use unconstrained JSON instead of guessing a type. Optional multipart operations require a supplied body in Swift, which may be empty. Constraints such as lengths and numeric ranges are generally enforced by the server, rather than a generated validator.

## Native Swift model and transport contracts

The pinned generator patch adds open string/integer enums, unknown oneOf/anyOf variants, and `jsonMetadata` to nested Codable models. Malformed fields receive Swift zero defaults while their metadata reports `.invalid`; missing and null remain distinct. `OpenAIJSON.decode` retains exact JSON spans when decoding directly. Generated client responses install that context automatically, including for nested array elements. Unknown variants retain `RawJSONValue.data` for lossless inspection or raw forwarding. Dynamic `JSONValue` decoding preserves numbers outside ordinary Swift numeric precision/range as `JSONNumber`; `encodedData()` and facade JSON requests preserve those numeric lexemes. Foundation's ordinary `JSONEncoder` still has a finite numeric range and throws for unsupported `JSONNumber` values; forward the retained bytes or use `JSONValue.encodedData()` in that case.

Every generated object exposes `jsonOverrides`: use `.omitted`, `.null`, or `.value(JSONValue)` with wire-key names, including unknown fields. This also works through recursive storage and flattened schema components. Metadata and overrides do not become request fields. Typed Swift initializers remain available. The patch is checksummed against Apple generator 1.14.0 and applied by the regeneration script; no generated Swift files are hand-edited.

X.509 clients share issuer/API retry scopes and use the sealed capability through `Client(x509:)`. Native application-owned TLS identities replace Go's arbitrary crypto-signer interface on supported Apple platforms. The Swift implementation uses native Swift concurrency and platform TLS, with the specific contracts in `Providers.md`. Both Swift transports share retryable HTTP/network decisions. Server-directed waits above the configured maximum stop retries and preserve the original HTTP failure; valid waits are honored exactly. Generated clients also recover one rejected OAuth token within the ordinary retry budget, respecting explicit authorization and upload replayability. Full Go SDK parity must not be inferred from endpoint or schema counts.
