# Contributing

Use Swift 6.2 or later. Read [AGENTS.md](AGENTS.md) and the Swift style guide it references. Keep source grouped by API family, document public contracts, and keep provider-specific behavior explicit.

From the package root, run:

```sh
sh scripts/format.sh
sh scripts/check-format.sh
swift build
swift test
```

Avoid concurrent SwiftPM builds in the same build directory. Add behavior tests for changed wire formats, stream ownership, error paths, or retry semantics. Use fixture transports and local HTTP fixtures for deterministic checks; label any live provider check with its server/model and results. Do not describe fixture validation as live inference or untested platforms as verified.

The example in `Examples/Sources/OllamaChat/main.swift` belongs to a separate executable package. Verify it with `swift build --package-path Examples`; run it with `swift run --package-path Examples ollama-chat [model] [prompt]`, replacing the optional placeholders with actual arguments. Add `--stream` for streaming. The default `llama3.2` model must already be installed on the selected Ollama server.

For an end-to-end check without a model server, run `python3 scripts/smoke-example.py /absolute/path/to/ollama-chat` against the built example. It serves an isolated localhost fixture and verifies completed and streamed output, usage, URL prefixes, prompt serialization, and Ollama credential isolation. The Swift integration tests and this smoke check require localhost socket access and Python 3.

When adding an evolving endpoint, choose a typed model where it improves the call site and JSON where preserving the full schema is useful. Maintain `Documentation/Compatibility.md` whenever coverage or platform verification changes. Do not copy generated upstream source or license headers into independently written code.

The complete REST inventory is pinned in `Documentation/Reference/openai-go-endpoints.json`. After updating the inventory from official root and linked API references, run `python3 scripts/generate-endpoints.py` and `python3 scripts/generate-endpoints.py --check`. Follow the source-download and comparison instructions in `Documentation/EndpointCoverage.md`; do not infer coverage from a passing mock dispatch test alone. Add behavior tests for new wire protocols and non-JSON bodies.

Do not hand-edit or format `Sources/OpenAIAPI/Generated`. Update the schema overlay or checksummed generator patch, then run `ruby scripts/regenerate-api.rb` and its `--check` mode. Check the separate hand-written helper inventory with `ruby scripts/check-helper-coverage.rb /path/to/pinned/openai-go`; this verifies source mappings, while the fixture suite verifies behavior. Update the helper source checksum manifest only when deliberately changing the pinned reference.

Type-check complete documentation snippets against the built public module with `python3 scripts/check-doc-examples.py /absolute/path/to/build/products`. The directory must contain `OpenAI.swiftmodule`; `swift build --show-bin-path` normally supplies it. The script excludes the two package-manifest fragments, which require a surrounding manifest.
