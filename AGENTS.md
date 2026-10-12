# OpenAI Swift package

Read [the Swift project style guide](/Users/stephen/.codex/guides/swift-project-style.md) before Swift source work. Use four spaces and `swift format`; preserve explicit JSON wire keys and existing public APIs unless a change is required.

Keep services in their API family and shared HTTP/SSE infrastructure in `Sources/OpenAI/Core`. The root package exports OpenAI and OpenAIAPI. Keep Apple generator output under Sources/OpenAIAPI/Generated unchanged; update the pinned schema overlay and regenerate instead. The optional AWS SDK integration is a separate package under Integrations/Bedrock. `Examples` is a separate executable package consuming that library.

Run `swift build`, `swift test`, and formatting checks from this directory. Do not run competing SwiftPM builds against the same build directory. Test streaming fragmentation, cancellation, retries, and multipart behavior where changes affect them.

Keep scope and verification claims accurate in `Documentation/Compatibility.md`. HTTP access and JSON resource wrappers are distinct from generated full-schema SDK parity. Label fixture checks, local HTTP integration, platform checks, and live provider inference separately. Do not claim untested providers or platforms work.
