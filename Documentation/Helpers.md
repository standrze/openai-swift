# Workflow helpers

These native Swift helpers correspond to the hand-written helpers in the pinned
Go SDK. They use the same client authentication, request options, retries, and
transport as ordinary resource operations. A provider must implement the
underlying endpoints; Ollama does not acquire hosted Agents or vector stores
merely by using this client.

## Polling and uploads

`APIResource.pollStatus` and `createAndPoll` cover vector-store files and batches.
`VideosService` supplies multipart `createAndPoll` and `pollStatus`. Terminal
failed/cancelled records are returned for inspection. Unknown statuses fail.
Polling adds the Stainless poll headers and chooses an interval once: an explicit
positive millisecond interval wins, otherwise the first server suggestion is
capped at eight seconds, with a one-second fallback. Task cancellation and
`RequestOptions.deadline` interrupt both requests and waits.

```swift
import Foundation
import OpenAI

func indexNotes(client: OpenAIClient, storeID: String) async throws -> JSONValue {
    try await client.vectorStores.uploadFileAndPoll(
        FileUpload(filename: "notes.txt", data: Data("Swift notes".utf8)),
        storeID: storeID
    )
}
```

`uploadFile` uploads and attaches one file. `uploadFileBatchAndPoll` uploads
concurrently, waits for the uploads, and creates/polls the batch only if every
upload succeeded. `fileIDs` adds existing uploads. Files remain application-owned
on failure; these helpers never delete them automatically.

## Chat completion boundaries

`ChatCompletionAccumulator.justFinishedContent`, `justFinishedRefusal`, and
`justFinishedToolCall` inspect the transition caused by the most recent chunk.
Their optional `forChoice` argument selects a particular choice; omission retains
the Go helper's first-choice behavior. A subsequent `add`, including a rejected
chunk, clears these notifications. Interleaved parallel tool calls do not provide
reliable individual completion boundaries. Sparse tool indices are bounded;
choice indices are limited to 0...127 and tool index -1 means index zero.

`ChatMessage.asAssistantMessage()` converts response output to reusable assistant
input, retaining function/custom calls and provider reasoning extensions while
dropping response-only annotations and audio bytes. `AgentMessage.outputText`
joins only output_text blocks.

## Hosted Agents turns and local tools

`createSessionStream` creates a hosted session. `stream(sessionID:input:)` checks
that an existing session is idle, subscribes before submitting input, and observes
one coordinator turn through its following idle event. Use one input writer per
session while the helper runs. Input is nonempty text or a JSON message array.
Each input receives a stable idempotency key across HTTP retries; every local
tool result receives its own key. The helper retries the API's specific pending
call registration race without executing the local handler again.

```swift
import OpenAI

func runAgent(client: OpenAIClient, sessionID: String) async throws -> String {
    let stream = try await client.beta.agents.stream(
        sessionID: sessionID,
        input: "Summarize the supplied record.",
        toolHandlers: ["lookup": { arguments in
            ["record": arguments["id"] ?? .null]
        }]
    )
    defer { stream.close() }
    let result = try await stream.finalResult()
    return result.outputText
}
```

Only explicitly registered handlers execute, sequentially on the iteration after
their function-call event is returned. Unknown functions remain available for
manual handling. Duplicate events/calls do not execute handlers twice. Handlers
receive value-semantic JSON objects and return null, text, an object (serialized
to JSON text), or an input-content array. Invalid arguments, handler errors, and
invalid outputs send only `Tool handler failed.`. The optional `onToolError`
callback receives the original application diagnostic; it is never transmitted.

Fresh `finalResult()` calls enable collection. To iterate progress first, call
`try await stream.withResultCollection()` before the first event. Collection
retains the initial root turn's completed assistant messages, excludes commentary
and subagent messages, sorts output indices, and caches the result or failure.
`AgentTurnResultError` distinguishes hosted failure/cancellation, required manual
action, incomplete observation, failed observation, and late collection. It
retains partial messages, actions, and the original cause. Its description does
not include output. Closing/cancelling observation does not cancel the remote
turn. Custom handlers must cooperate with Swift task cancellation.

## Typed Agents output

`AgentOutput<Value>` normalizes an object-root schema: objects are closed and all
properties required. Nested anyOf and local definition references are supported;
unsupported composition/keywords, remote references, and invalid scalar literals
fail locally. Remaining schema constraints are validated by the API.

```swift
import OpenAI

struct Report: Decodable, Sendable {
    let summary: String
}

func reportOutput() throws -> AgentOutput<Report> {
    try AgentOutput(schema: [
        "type": "object",
        "properties": ["summary": ["type": "string"]]
    ])
}
```

Put `output.format` in the session's `text.format`, then call
`try await output.finalResult(stream)` or `output.parseResult(result)`.
A custom parser can validate application constraints. Parsing failure retains the
completed raw result in `AgentOutputParseError`, independently of hosted failure.
`schemaJSON:parse:` preserves exact numeric literals when loading a schema.

## Local files and result artifacts

`prepareFiles` maps clean absolute /workspace destinations to local file URLs.
It preflights the entire selection before uploading: regular source files,
nonoverlapping destinations, and reserved environment paths. Sources must be
application-controlled and stable during preparation. `prepareDirectory` uses
explicit relative POSIX glob patterns, visits selected paths, and skips symlinks
and symlink parents. It is a one-time selection, not synchronization or a sandbox.
Upload count/size/path-length limits remain server-owned.

`AgentPreparedFiles.files` contains hosted environment inputs; `uploads` contains
the owned Files API records. `uploadEnvironmentFile` additionally stages one file
in an existing environment. If a later upload or staging step fails,
`AgentFilePreparationError.prepared` retains successful uploads for explicit
cleanup. Multi-file preparation rejects reuse of one idempotency key.

`agents.artifacts(for: result).find(path:)` paginates and selects an exact
session/turn/path match. Missing or ambiguous matches fail. `download(path:write:)`
streams to the application's writer and returns artifact metadata; it never
interprets a remote path as a local destination. Writer failures close the body
and retain metadata in `AgentArtifactDownloadError`.

## Hand-written Go helper comparison

| Go source | Swift equivalent |
| --- | --- |
| polling.go; vectorstorefile_helpers.go; vectorstorefilebatch_helpers.go | APIResource polling; VectorStoresService uploads; VideosService polling |
| streamaccumulator.go and supporting ownership/logprob files | Value-semantic ChatCompletionAccumulator; indexed completion boundaries |
| chatcompletion_helpers.go | ChatMessage.asAssistantMessage |
| agents_message.go | AgentMessage.outputText; AgentTurnResult.outputText |
| agents_stream.go; agents_tools.go; beta_agents_creation_stream.go | AgentSessionStream; AgentsService stream/createSessionStream |
| beta_agents_result.go | AgentTurnResult, AgentTurnResultError; collection/finalResult |
| beta_agents_output.go | AgentOutput; AgentParsedTurnResult; AgentOutputParseError |
| beta_agents_files.go | File preparation/staging and AgentResultArtifacts |
| beta_agents_tool_error.go | AgentToolError and onToolError |
| responses/response_helpers.go | Response.outputText |
| responses/response_accumulator*.go | ResponseWebSocketAccumulator and detailedSnapshot |
| responses/responses_websocket.go | Connections, lanes, recovery, abort, and terminal finalResponse |

Endpoint/schema coverage and helper source comparison are separate checks.
Fixture tests exercise workflow semantics; they do not establish hosted service
availability or live inference. See [Parity.md](Parity.md) and [Verification.md](Verification.md).
