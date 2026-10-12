# Live Ollama verification

On October 11, 2026, all **21 live compatibility checks passed** against Ollama
0.31.1 on macOS arm64 with an Apple M5 Max. The executable used the SDK's native
HTTP transport and real local model inference throughout. It did not substitute
mock responses. [Machine-readable results](Reference/ollama-live-2026-10-11.json)
contain individual outcomes and durations; [model metadata](Reference/ollama-live-models-2026-10-11.json)
records the exact local digests behind the mutable tags.

The follow-up model-route verification passed **6/6 live checks** against the
running Ollama **0.35.1** server. Facade, raw request/download, raw streaming, and
generated retrieval each resolved all six installed IDs, including
`yandex/YandexGPT-5-Lite-8B-instruct-GGUF:latest`. The disabled-workaround and
unknown-ID controls retained 404. [Model-route results](Reference/ollama-model-retrieval-live-2026-10-11.json)
record this separate run; it did not repeat inference or load model weights.

| Model | Live coverage |
| --- | --- |
| `gpt-oss:latest` | Chat and legacy completions, streaming/usage/cancellation, reasoning, Responses, strict JSON schema output, function calls, and tool-result replay |
| `all-minilm:22m` | Batched float embeddings and base64 float32 embeddings; 384 dimensions |
| `gemma4:26b` | Image input with a PNG data URL and returned assistant text |

Model listing and retrieval covered all six installed models, including a
namespaced ID. Generated `OpenAIAPI` calls covered model listing, chat, Responses,
and embeddings. A nonexistent model returned a preserved HTTP 404 `APIError`.
The vision check establishes image transport and response decoding, not visual
reasoning accuracy. These short checks do not measure general model quality or
make a latency benchmark.

## Compatibility fixes found by live calls

- Ollama returns chat reasoning in `reasoning`. `ChatMessage` and
  `ChatCompletionDelta` now retain this field separately from `reasoning_content`;
  the accumulator joins its fragments. Assistant-message projection preserves
  both extensions for tool replay.
- Responses sends reasoning-summary deltas alongside answer deltas.
  `ResponseEvent.textDelta` now returns only `response.output_text.delta` text.
  Other channels remain available through `delta` and `rawValue`. Refusal and tool
  accumulators consume their own delta fields without mixing them into answers.
- Ollama 0.31.1's model-detail route returns 404 for an escaped slash in a
  namespaced model ID. `ClientConfiguration.ollama()` enables
  `modelRetrievalFallback`: after that specific 404, the configured transports
  select the exact ID from `/v1/models`. This covers the facade's `models.retrieve`,
  raw SDK request/download/stream calls, and generated `retrieveModel` when created
  with `Client(openAIConfiguration:)`. Unknown IDs retain the
  original 404. Other statuses, non-namespaced IDs, and ordinary OpenAI clients
  do not trigger it. Set the flag to false to retain literal endpoint behavior.
  Lookup preserves the origin, query, headers, and enclosing attempt deadline.
  Selected JSON retains unknown metadata and numeric values; representation
  headers are rebuilt for the selected body rather than copying listing validators.
  Streamed lookup bodies are bounded by `maxEventBytes` and release both connections.
  A failed or malformed listing preserves the original model response. A transport,
  deadline, or body-limit failure remains an error. The lookup shares its enclosing
  attempt; it has no independent retry loop.
  The server still rejects the literal HTTP route on 0.35.1; the SDK handles this
  through the opt-in configuration, without changing generated source. A generated
  client constructed directly with `serverURL:` has no provider configuration and
  retains literal behavior.

An initial legacy completion with a 24-token budget returned empty answer text
because GPT-OSS spent its budget on reasoning. A direct server request and the SDK
both returned `Paris.` with a 256-token budget. This required a live-runner budget
adjustment, not a protocol change.

Eleven deterministic regression tests additionally cover reasoning retention,
delta channel separation, fallback scope/options, raw/generated retrieval, unknown
metadata, stream cleanup, disabling the workaround, and original model errors.
The ordinary regression suites run without an Ollama dependency.

## Reproduce

Start a local server with bounded context and one loaded model:

```sh
OLLAMA_CONTEXT_LENGTH=4096 OLLAMA_MAX_LOADED_MODELS=1 ollama serve
```

In a second terminal, from the package root:

```sh
swift build --package-path Examples --product ollama-compatibility
OLLAMA_MODEL=gpt-oss:latest \
OLLAMA_EMBEDDING_MODEL=all-minilm:22m \
OLLAMA_VISION_MODEL=gemma4:26b \
OLLAMA_REPORT_PATH=/tmp/ollama-live.json \
swift run --skip-build --package-path Examples ollama-compatibility
```

Models must already be installed; the executable never pulls them. The embedding
and vision groups are opt-in through their environment variables. Omit those
variables to run the 20 core checks (24 with both optional groups). At least one
namespaced model must be installed to exercise the route workaround. To run only
the six model-route checks, without inference:

```sh
OLLAMA_MODELS_ONLY=1 OLLAMA_REPORT_PATH=/tmp/ollama-models.json \
swift run --skip-build --package-path Examples ollama-compatibility
```

Set `OLLAMA_BASE_URL` to a different server's
complete OpenAI API prefix. The runner uses zero retries and a 120-second attempt
deadline, reports every check, writes optional JSON, and exits nonzero on failure.
Input prompts and outputs are synthetic and intentionally short. The generation
model should support tools and reasoning for this suite.

The test session started a previously stopped local Ollama server and added the
small `all-minilm:22m` embedding model. It used the existing GPT-OSS and Gemma 4
weights. The task's server was stopped after verification to release model memory.
The later model-route run reused the already running server and left it running.

The live scope follows Ollama's [OpenAI compatibility endpoints](https://docs.ollama.com/api/openai-compatibility).
Hosted OpenAI, stateful hosted workflows, WebSockets, media generation, and cloud
authentication are outside this live run. Their fixture/platform verification is
recorded separately in [Verification.md](Verification.md).
