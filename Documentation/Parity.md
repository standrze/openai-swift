# Go SDK parity audit

Target: `openai/openai-go` v3.76.0, revision
`2922f3e8a846d561d85e4aabb90f017c2de10851`. Swift equivalents follow native
Swift concurrency and Codable conventions; identical Go syntax is not a goal.
The source snapshot is the comparison target, not a promise that every provider
implements every OpenAI endpoint.

| Capability | Swift implementation | Verification/status |
| --- | --- | --- |
| All six Go API catalogs | `RESTEndpoint`, resource services | 340 named methods, 339 query-aware routes; coverage script |
| Full request/response schemas | `OpenAIAPI` generated client | Official schema, 359 operations, no skipped definitions |
| Future string enum values | `JSONStringEnum`, `.undocumented(String)` | Nine model parity tests passed |
| Unknown oneOf/anyOf variants | `RawJSONValue`, generated fallback cases | Nine model parity tests passed |
| Known wire discriminators | Schema overlay materializes literal mappings | User-message and event selection regressions |
| Nested response raw JSON and extra fields | `JSONMetadata`, `OpenAIJSON` | Nested large-number and malformed-field regressions |
| Exact dynamic JSON numbers | `JSONNumber`, `JSONValue.encodedData()` | Beyond-Double precision, large exponent, request-mutation and schema-integer regressions |
| Missing/null/invalid response fields | Generated zero defaults and field states | Nine model parity tests passed |
| Typed values, omission, null, arbitrary request fields | `JSONParameter`, generated `jsonOverrides` | Nine model parity tests passed |
| API/admin keys, webhook secret, and provider base URLs | `ClientConfiguration`, `RequestOptions` | Transport fixtures and example consumer |
| Header/query set, add, delete | Ordered `HeaderMutation`, `QueryMutation` | Request mutation tests passed |
| Complete request-body replacement | `RequestBodyOverride` | Request mutation tests passed |
| Raw responses and application-owned types | `download`, `APIResult`, `withResponse` | Existing SDK parity tests |
| Middleware and per-attempt signing | `ClientMiddleware`, `prepareAttempt`, runtime middleware | Ordering/retry fixtures |
| Retry count, backoff, server-directed waits | Shared `HTTPRetryPolicy` | Server-limit regression passed |
| Final request origin after middleware/signing | Shared origin validation in both transports | Origin and authority replacement regressions |
| Total and per-attempt timeout scope | URLSession timeouts and Swift cancellation | Authentication/retry/wait/body and generated-body deadline regressions |
| Pagination and SSE | Cursor pages, async sequences, accumulators | Fragmentation, cancellation, cursor fixtures |
| Vector-store and video workflow helpers | Poll/create-and-poll; file/batch upload-and-poll | Poll headers, interval selection, terminal states, deadlines and wait-all upload fixtures |
| Chat completion helper transitions and request projection | Finished content/refusal/tool calls per choice; `asAssistantMessage` | Sparse indices, rejected chunks, ownership and custom-call fixtures |
| Hosted Agents streaming and tools | `AgentSessionStream`, registered local handlers, stable idempotency keys | Subscribe-before-input, deferred dispatch, deduplication, registration-race retry and redaction fixtures |
| Hosted Agents results and typed output | Root-turn collection; `AgentOutput` schema normalization/parsing | Completed message selection, partial failures, strict schemas and parse-error fixtures |
| Hosted Agents files and artifacts | Local selection/preflight, staging, exact artifact lookup and streaming download | Symlink/path checks, partial upload ownership, pagination and writer-failure fixtures |
| Hand-written helper inventory | Checksummed pinned Go helper sources and Swift mappings | 50 public methods mapped separately from endpoint coverage; behavioral fixture tests |
| Multipart and binary bodies | Facade multipart and generated streaming `HTTPBody` | Upload and single-use replay fixtures |
| Webhooks | Signature verifier and typed event wrappers | HMAC/timestamp fixtures |
| Responses/realtime WebSockets | Native transport, lanes, recovery, accumulators, abort and queue accounting | Native localhost and routing fixtures |
| WebSocket abort, close timeout, unlimited/byte limits | Native lifecycle, exact wire-byte accounting, and optional session limits | Localhost and queue regressions |
| WebSocket receive cancellation, fallback routing and recovery | Pull queues, default receiver, cancellable opening/restoration | Receive reuse, detached/unclaimed events, failed restore disposal and close-during-opening fixtures |
| Responses WebSocket accumulation and final responses | Lane-bound sparse/detailed snapshots; return all terminal server responses | Mixed-lane, lexical index, metadata and failed/incomplete response fixtures |
| Workload identity | OAuth exchange/cache; Kubernetes, Azure, GCP subject sources | Cache/rotation/cloud request fixtures |
| X.509 workload identity | Native TLS identity, restricted issuer/API capability | Local mTLS presentation and trust fixtures |
| X.509 token parsing/redaction/history | Strict duplicate/lifetime/bearer parsing, digest history | Strict parsing and redaction regressions |
| X.509 shared issuer/API retry/deadline scope | Task-local operation scope, independent follower budgets, whole-exchange deadline | Issuer/API budget, follower, late-401 and zero-retry regressions |
| Azure deployment routing | Azure factory and per-attempt routing | JSON, binary multipart model extraction, and escaped-prefix fixtures |
| AWS Bedrock | Official AWS SDK resolver and SigV4; bearer mode | Five integration tests passed, including named-profile region resolution |
| Apple/Linux platforms | Conditional FoundationNetworking/Security and NIO boundaries | macOS/Linux fixture suites and full iOS/tvOS/watchOS builds; see verification record |
| Live Ollama inference | Ollama 0.31.1; GPT-OSS, MiniLM, Gemma 4 | 21 live checks passed; scope, fixes and model digests in LiveOllama.md |
| Live Ollama model-route workaround | Ollama 0.35.1; all six installed IDs | Six checks passed across facade, raw REST/streams, generated retrieval, and error controls |
| Hosted provider inference | Requires provider account credentials | Not performed; Ollama and fixtures do not verify hosted providers |

## Generator patch

Apple's pinned generator remains responsible for schema parsing, Swift naming,
Codable structure, and HTTP operations. The small patch in
`Tools/Generator/Patches` adds SDK-specific forward compatibility and model
metadata to its existing translation steps. `patch-generator.rb` verifies every
pristine/patched file by SHA-256 before applying it. The schema overlay separately
records each adaptation. `scripts/regenerate-api.rb --check` must reproduce all
checked-in generated Swift files.

## Native Swift equivalents and boundaries

The feature comparison is against the pinned Go revision. Swift async sequences,
Codable values, closures, and native TLS identities replace Go interfaces and
syntax. Endpoint/schema coverage is generated and checked; fixture tests exercise
transport and model contracts rather than every possible server response.

- Exact response JSON is retained for inspection and raw forwarding. Dynamic
  `JSONValue` uses `JSONNumber` when necessary; `encodedData()` and facade JSON
  requests preserve arbitrary numeric lexemes. Foundation's ordinary JSON encoder
  has a finite numeric range and rejects unsupported exact values.
- SSE defaults bound decoded queues to 256 events and each event to 8 MiB, unlike
  Go's pull scanner and its per-line limit. Configure limits for the workload.
  Responses session queues default to unlimited. Linux's NIO WebSocket decoder
  limits a single frame to 4 GiB; configurable complete-message limits apply above it.
- Apple's Security framework supplies static X.509 identities and platform-backed
  keys. Arbitrary Go crypto signers are represented by application-owned native
  identities. Linux certificate identities require a separate transport; this
  package does not provide an Apple Security replacement there.
- One cancelled OAuth waiter leaves the shared exchange available to other
  callers. Caller deadlines still bound their own waits and X.509 exchanges.
  Custom asynchronous transports/providers must cooperate with cancellation.
- Generated multipart bodies can contain single-use parts, so automatic replay is
  suppressed. The facade's collected multipart bodies support replay. The generated
  `FacadeTransportAdapter` collects request bodies and streams response bodies.
- Apple device checks compile the full package but do not establish device runtime
  behavior. Windows and live provider accounts are outside the verified platform
  matrix. Live inference is separate from SDK feature coverage.
