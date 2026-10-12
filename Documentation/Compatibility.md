# Compatibility and scope

The package now includes an Apple-generated full-schema API, deep JSON/request hooks, raw result metadata, streaming files, managed WebSocket lanes, cloud subject-token providers, Azure routing, a separate AWS SDK integration, and Apple native client certificates. Read [GeneratedAPI.md](GeneratedAPI.md) and [Providers.md](Providers.md) for contracts and remaining differences. The [parity matrix](Parity.md) records the pinned Go feature comparison and native Swift/platform differences.

This independently implemented Swift package uses [openai-go](https://github.com/openai/openai-go) as a model for service organization, request options, streaming, and resource access. Its named REST catalog covers every operation in the pinned root and linked upstream API references: 340 named operations, representing 339 distinct HTTP method/path pairs at revision `2922f3e8a846d561d85e4aabb90f017c2de10851`. See [EndpointCoverage.md](EndpointCoverage.md) for the reproducible inventory. The ergonomic facade uses typed common inference models and JSON resource wrappers. The additional OpenAIAPI module generates the complete pinned OpenAPI schema surface.

## API surface

| Area | Surface in this package |
| --- | --- |
| Chat Completions | Typed create/stream, multimodal content, function/custom tools, structured output, usage/logprobs, stored completion operations, indexed accumulation and completion-boundary helpers |
| Legacy Completions | Typed create/stream; text, text batches, token IDs, token batches |
| Responses | Typed common request/response/event fields; structured input/tool JSON; retrieve/delete/cancel/input items/compact/input-token methods; indexed stream accumulator |
| Models, embeddings, files | Typed model metadata, vectors, file lifecycle and binary downloads |
| Images, audio, moderation, batches | Typed common parameters/results, media upload/download, image/audio SSE with JSON events, batch lifecycle |
| Fine-tuning, vector stores, uploads, conversations | Named JSON resources, lifecycle actions, upload parts, nested access, stream/download helpers, vector-store polling and upload-and-poll |
| Assistants, threads, containers, evals | Named JSON resources, runs/tool outputs/SSE, binary file content, inherited beta versions |
| Agents | Named JSON resources, turn streaming/result collection, local tool handlers, typed output schemas, local file preparation, staging, and artifact downloads |
| Vaults, ChatKit, skills, videos, Live | Named JSON resources, lifecycle actions, uploads/downloads, events, and video create-and-poll |
| Administration, decisions, safety, provenance, webhook configuration | Named resources and full `RESTEndpoint` operation catalog |
| Realtime | WebSocket JSON events, REST setup/call control, multipart SDP offers and raw SDP option |
| Responses WebSockets | Persistent JSON connection, response.create, typed events, terminal-response collection, lane sessions, explicit recovery, abort, and detailed indexed accumulation |
| Webhook verification | Standard Webhooks HMAC-SHA256, raw bytes, timestamp tolerance, rotation signatures, preserved event JSON |
| Authentication | API keys, explicit headers, async bearer providers, cached OAuth client credentials, RFC 8693 exchange, OpenAI workload identity JSON exchange |
| Every cataloged HTTP operation | JSON or application-owned types, multipart, original binary bytes, SSE, and incremental byte streams |

JSON resources preserve their complete response objects. Responses output and stream event models retain `rawValue` for future fields. Typed chat/media models retain declared fields; use generic `JSONValue` decoding when all unmodeled response fields must be preserved. Model names, roles, formats, termination reasons, and many provider values remain open strings. Unknown chat content parts, declared tool definitions, output formats, and tool choices have custom JSON variants.

The library handles HTTP, SSE, WebSocket JSON messages, authentication, and webhook verification. Applications supply tool implementations; hosted Agents helpers can dispatch explicitly registered handlers. Applications own microphone/speaker capture, WebRTC media and peer connections, webhook HTTP hosting and event-ID deduplication, and any provider-specific authorization policy. WebSocket connections are explicitly closed, have one active receiving consumer, and never automatically reconnect or replay events. The underlying WebSocket transport is injectable. See [Helpers.md](Helpers.md) for workflow ownership and cancellation contracts.

The catalog pin defines endpoint completeness; newer upstream operations require an inventory update. Catalog descriptors preserve paths, verbs, identifier names, and version defaults. They do not provide generated validation for every body field. Invalid or unsupported provider parameters remain server errors, and generic SSE calls require the caller to supply the endpoint's streaming body/query flag. Upload and raw-byte helpers retain response metadata for endpoints that return SDP, content, or empty replies.

## Ollama and other servers

Configure the complete API prefix, usually `http://localhost:11434/v1`. `.ollama()` sends no API key and does not inherit cloud credentials. The library implements OpenAI HTTP wire formats, rather than Ollama's native `/api` endpoints.

Ollama's [compatibility guide](https://docs.ollama.com/api/openai-compatibility) describes chat, legacy completions, Responses, models, and embeddings support. Its documented support is a subset with endpoint-specific limits; for example, legacy `prompt` currently accepts a string. Consult the server's current documentation before using stored responses, hosted tools, media, files, or administrative endpoints. An available Swift service does not imply that a provider serves that endpoint or that a selected model supports its parameters.

There is no capability probing. Azure routing is an explicit provider adapter; ordinary OpenAI-compatible clients do not automatically rewrite requests. The server reports unsupported parameters and operations through the normal HTTP error path. Use `RequestOptions.extraBody` for vendor fields, and custom base URLs for other compatible servers.

The Ollama factory enables a narrowly scoped namespaced-model retrieval fallback: on a model-detail 404, configured transports select the exact ID from `/v1/models`. This covers resource helpers, raw SDK REST calls, and generated clients constructed with `openAIConfiguration:`. Other clients retain literal behavior; set `modelRetrievalFallback` to false to disable the workaround. Chat models retain Ollama's `reasoning` field separately from `reasoning_content`; `ResponseEvent.textDelta` exposes only answer text, while reasoning/tool/refusal deltas remain in their own event payloads. See [LiveOllama.md](LiveOllama.md) for the observed issues and fixes.

## Verification status

Package verification uses Swift 6.4 on macOS and Linux arm64. Unit tests and localhost HTTP/WebSocket fixtures exercise requests, streaming transport, and wire-format behavior. macOS additionally exercises native TLS client identities. The package declares Swift tools version 6.2 and Apple deployment minimums in `Package.swift`; those declarations are distinct from runtime test results.

The complete expanded package builds for iOS 16 arm64, tvOS 16 arm64, and watchOS 9 arm64_32 using SDK 27. These compile checks do not establish device runtime behavior. Linux transport verification is recorded in [Verification.md](Verification.md). All 21 inference-suite checks passed on Ollama 0.31.1 using GPT-OSS, MiniLM, and Gemma 4, followed by six model-route checks on Ollama 0.35.1; the exact scope and model digests are in [LiveOllama.md](LiveOllama.md). Hosted OpenAI calls remain untested. No model-quality or latency claim follows from the short live checks or fixture tests.
