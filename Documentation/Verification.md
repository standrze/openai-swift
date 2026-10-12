# Verification

Verified on October 11, 2026 using Swift 6.4 on macOS arm64 and Linux arm64
(`swift:6.4-trixie`). Tests use controlled fixtures unless explicitly described as
native localhost integration or live Ollama inference. The comparison target is Go SDK v3.76.0 at
`2922f3e8a846d561d85e4aabb90f017c2de10851`.

| Check | Result |
| --- | --- |
| macOS main package | 280 XCTest tests passed: 253 facade and 27 generated-client tests, zero failures |
| Linux main package | 277 XCTest tests passed: 250 facade and 27 generated-client tests, zero failures |
| Live Ollama | 21 inference-suite checks passed on 0.31.1; six follow-up model-route checks passed on 0.35.1, including raw/generated namespaced retrieval; exact results and digests in LiveOllama.md |
| Optional AWS package | Five tests passed: official SigV4 body/session-token signing, escaped URI preservation, bearer isolation, credential/endpoint validation, and named-profile region resolution |
| Pinned Go endpoint comparison | 340 named operations / 339 distinct query-aware routes; no missing routes from the six pinned API references |
| Hand-written helper comparison | Checksummed reference inventory maps 50 public Go helper methods across 12 files; workflow behavior is checked separately by fixtures |
| Generated API | Official schema has 359 operations and 2,048 original component schemas; regeneration matched all nine checked-in Swift files, with no skipped definitions |
| Native localhost HTTP | Eight tests cover JSON/auth, unlimited timeout, bytes/headers, multipart, incremental SSE, cancellation, redirects, and token-transport redirect rejection |
| Native localhost WebSocket | Eight tests cover upgrade/auth, framing/control frames, binary payloads, rejected upgrades, timeouts, cancellation, limits, redirects, and immediate abort on Apple and Linux backends |
| Native localhost TLS on macOS | Imported in-memory PKCS#12 identity presented its client certificate; an untrusted server was rejected without hanging; invalid identity and closed-capability checks passed |
| OAuth and advanced contracts | Shared refresh, cancellation, rejected-generation history, explicit-auth retries, shared issuer/API budgets, deadlines, strict token parsing/redaction, middleware/signing, metadata, mutations, Azure routing, and Kubernetes token rotation passed fixtures |
| Workflow helpers | Polling/upload, chat completion transitions, hosted Agents tools/results/schemas, local file selection, partial upload ownership, and artifact streaming passed fixtures |
| Responses WebSocket session | 15 tests cover queue accounting, default/named routing, receive/send cancellation, lane lifetime, overflow, reconnect/restore without replay, failed restoration disposal, and close during opening |
| Exact JSON and accumulation | Arbitrary numeric lexemes round-trip through dynamic JSON and request mutations; lane-bound WebSocket accumulation preserves detailed sparse indices and terminal server responses |
| Live-discovered compatibility regressions | Eleven tests cover Ollama reasoning retention/accumulation, Responses delta-channel separation, namespaced-model fallback scope/options, raw/generated retrieval, metadata, stream cleanup, disabling fallback, and original errors |
| Streaming file body | Bounded chunks, replay, truncation rejection, invalid chunk size, serialized multipart bytes, and suppression of single-use retries passed |
| Independent consumer | `Examples` built; completed/streaming chat passed an isolated localhost fixture with prefix, prompt, usage, and credential-isolation checks |
| Documentation | 22 complete Swift examples passed external module type checking; two package-manifest fragments excluded |
| Apple device targets | Full package/dependency graph built for iOS 16 arm64, tvOS 16 arm64, and watchOS 9 arm64_32 with SDK 27 |
| Formatting | `scripts/check-format.sh` passed; generated source is checked through regeneration instead |

The generated schema overlay records 1,939 adaptations. Diagnostics retain parser
warnings about nullable/composite schemas and upstream constraints; generated
source compiles with deprecation warnings for legacy types and unused-import
warnings. No generation skip warnings remain. These checks establish source and
fixture coverage, not exhaustive testing of every model variant or operation
against a server. See [Parity.md](Parity.md), [GeneratedAPI.md](GeneratedAPI.md),
and [Helpers.md](Helpers.md) for the contracts and native boundaries.

Reproduction commands, from the workspace root:

```sh
NSUnbufferedIO=YES CLANG_MODULE_CACHE_PATH=/tmp/openai-module-cache swift test \
    --disable-sandbox --package-path openai \
    --scratch-path /tmp/openai-swift-build --cache-path /tmp/openai-swift-cache
CLANG_MODULE_CACHE_PATH=/tmp/openai-bedrock-module-cache swift test \
    --disable-sandbox --package-path openai/Integrations/Bedrock \
    --scratch-path /tmp/openai-bedrock-build --cache-path /tmp/openai-bedrock-cache
CLANG_MODULE_CACHE_PATH=/tmp/openai-generator-module-cache ruby openai/scripts/regenerate-api.rb \
    --check --disable-sandbox --scratch-path /tmp/openai-generator-build --cache-path /tmp/openai-generator-cache
python3 openai/scripts/check-endpoint-coverage.py /tmp
python3 openai/scripts/generate-endpoints.py --check
ruby openai/scripts/check-helper-coverage.rb /tmp/openai-go-reference
python3 openai/scripts/check-doc-examples.py /tmp/openai-swift-build/out/Products/Debug
CLANG_MODULE_CACHE_PATH=/tmp/openai-example-module-cache swift build \
    --disable-sandbox --package-path openai/Examples \
    --scratch-path /tmp/openai-examples-build --cache-path /tmp/openai-swift-cache
python3 openai/scripts/smoke-example.py /tmp/openai-examples-build/out/Products/Debug/ollama-chat
sh openai/scripts/check-format.sh
```

For Linux, copy the package to a temporary source directory and run `swift test`
inside `swift:6.4-trixie` with Python 3, Ruby, and OpenSSL installed. Keep the Docker
build/cache directories separate from Apple builds. The Linux suite excludes two
Apple Security tests and one CryptoKit comparison; Swift Crypto standard-vector
and native Linux networking tests still run.

Apple compile checks use separate scratch/module caches, SDK 27, and these triples:
`arm64-apple-ios16.0`, `arm64-apple-tvos16.0`, and
`arm64_32-apple-watchos9.0`. Pass the matching SDK directory with `swift build
--triple … --sdk …`. These checks include `OpenAIAPI` and the complete dependency
graph; they do not establish device runtime behavior. Windows remains untested.

Temporary caches and disabling SwiftPM's nested sandbox were needed in this
restricted workspace. Local HTTP/WebSocket/TLS tests and the example smoke need
localhost sockets; TLS needs Ruby/OpenSSL and skips if OpenSSL is unavailable.
The macOS run executed it successfully. [EndpointCoverage.md](EndpointCoverage.md)
provides the pinned downloads. Schema provenance, license, adaptations, generator
diagnostics, and helper checksums are under `Documentation/Reference`.

No live hosted OpenAI, Azure, GCP metadata service, Kubernetes cluster, AWS
credential chain, or enrolled OpenAI mTLS issuer was exercised. AWS signing uses
fixture credentials. Native TLS validates a local server and client identity;
certificate-authenticated WebSocket upgrades remain untested. Real Ollama inference
is separately documented in [LiveOllama.md](LiveOllama.md). These results do not establish model quality,
latency, hosted-provider conformance, or identical Go/platform runtime behavior.
