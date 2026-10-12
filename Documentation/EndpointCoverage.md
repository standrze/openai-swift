# REST endpoint coverage

Coverage is pinned to [openai-go revision 2922f3e8a846d561d85e4aabb90f017c2de10851](https://github.com/openai/openai-go/tree/2922f3e8a846d561d85e4aabb90f017c2de10851) and the six API references linked below. The inventory contains **340 named operations**, representing **339 unique method/path combinations**. The duplicate is the deprecated and current checkpoint-permissions GET operation. Counts include the beta Responses query variant.

All inventory operations have public `RESTEndpoint` selectors and dispatch through `client.api`. Named services add typed common models and ergonomic helpers for multipart uploads, binary downloads, SSE, and actions. The catalog uses `JSONValue` or application-owned response types for evolving schemas; it does not claim generated-model parity with openai-go.

## Inventory totals

| HTTP method | Named operations |
| --- | ---: |
| DELETE | 48 |
| GET | 151 |
| POST | 141 |

No PUT or PATCH operation appears in this pinned inventory. The generic client supports both for provider extensions.

| Upstream reference | Named operations |
| --- | ---: |
| [api.md](https://github.com/openai/openai-go/blob/2922f3e8a846d561d85e4aabb90f017c2de10851/api.md) | 303 |
| [conversations/api.md](https://github.com/openai/openai-go/blob/2922f3e8a846d561d85e4aabb90f017c2de10851/conversations/api.md) | 8 |
| [live/api.md](https://github.com/openai/openai-go/blob/2922f3e8a846d561d85e4aabb90f017c2de10851/live/api.md) | 7 |
| [realtime/api.md](https://github.com/openai/openai-go/blob/2922f3e8a846d561d85e4aabb90f017c2de10851/realtime/api.md) | 7 |
| [responses/api.md](https://github.com/openai/openai-go/blob/2922f3e8a846d561d85e4aabb90f017c2de10851/responses/api.md) | 7 |
| [webhooks/api.md](https://github.com/openai/openai-go/blob/2922f3e8a846d561d85e4aabb90f017c2de10851/webhooks/api.md) | 8 |

| Family | Named operations |
| --- | ---: |
| Admin | 124 |
| Audio | 4 |
| Batches | 4 |
| Beta | 83 |
| Chat | 6 |
| Completions | 1 |
| Containers | 9 |
| ContentProvenanceChecks | 1 |
| Conversations | 8 |
| Decisions | 1 |
| Embeddings | 1 |
| Files | 5 |
| FineTuning | 14 |
| Images | 3 |
| Live | 7 |
| Models | 3 |
| Moderations | 1 |
| Realtime | 7 |
| Responses | 7 |
| Safety | 2 |
| Skills | 11 |
| Uploads | 4 |
| VectorStores | 16 |
| Videos | 10 |
| Webhooks | 8 |

## Calling the catalog

Each table row below names a `RESTEndpoint` member. Identifiers use their upstream parameter names and are escaped as individual URL components. The operation chooses the HTTP method. Required beta headers/query parameters are inherited, and request options can override them.

```swift
let result = try await client.api.call(
    .adminOrganizationProjectsRetrieve,
    parameters: ["project_id": "proj_example"]
)

let archive = try await client.api.response(
    .skillsVersionsContentRetrieve,
    parameters: ["skill_id": "skill_example", "version": "2"]
)
```

Choose the representation appropriate to the endpoint:

- `api.call` returns JSONValue; `api.decode` decodes an application-owned type.
- `api.response` retains raw bytes, headers, status, and empty success responses.
- `api.upload` sends ordered multipart fields and files, preserving repeated names and part MIME types.
- `api.stream` consumes GET/POST SSE when the request includes the protocol streaming fields.
- `api.bytes` reads incremental original bytes. Applications own consumption and cancellation.

## Service and transport coverage

| Operation kind | Public convenience | Verification |
| --- | --- | --- |
| Chat, Responses, completions | `chat.completions`, `responses`, `completions`; typed requests, results, tool calls, SSE | ChatTests, ResourceTests, ServiceTests, StreamingTests |
| Images and audio | `images.generate/stream/edit/streamEdit/variations`; `audio.speech/speechStream/transcribe/transcribeJSON/transcribeStream/translate/createVoice` | ResourceTests, ServiceTests, AdvancedServiceTests |
| Files and multipart lifecycle | `files.upload/content`; `uploads.create/addPart/complete/cancel` | ServiceTests, AdvancedServiceTests, URLSessionIntegrationTests |
| Vector store parsed file content and batches | `vectorStores.files/fileContent/fileBatches/cancelFileBatch/listBatchFiles` | AdvancedServiceTests |
| Fine-tuning and checkpoint permissions | `fineTuning.jobs/events/jobCheckpoints/permissions/createPermission/deletePermission/runGrader/validateGrader` | AdvancedServiceTests |
| Conversations | `conversations` and nested `items`, including create/retrieve/list/delete item helpers | Catalog route dispatch and shared JSON transport tests |
| Assistants and thread runs | `beta.assistants`, `threads.createAndRun/createAndRunStream/createRun/streamRun/submitToolOutputs/submitToolOutputsStream/cancelRun` | AdvancedServiceTests |
| Agents and ChatKit | `agents` resources, nested session artifacts/items/turns/subagents/traces, `submitEvent/streamEvents`, `vaults.credentials`, `chatKit` | AdvancedServiceTests |
| Containers, skills, video media | `containers.uploadFile/fileContent`; `skills.create/createVersion/content/versionContent`; `videos.create/edit/extend/remix/createCharacter/content` | AdvancedServiceTests |
| Realtime SDP and call control | `realtime.createCall/acceptCall/hangupCall/referCall/rejectCall`, client secrets and translation secrets | AdvancedServiceTests |
| Live recordings and call actions | `live.create/accept/fork/downloadRecording/hangup/refer/reject` | AdvancedServiceTests |
| Webhook registration and secret actions | `webhooks` CRUD, `rotateSecret/test/eventTypes` | AdvancedServiceTests; webhook signature tests verify a separate concern |
| Decisions, content provenance, safety | `decisions.create`, `contentProvenanceChecks.create`, `safety.cases/alerts` | Catalog route dispatch; provenance multipart in AdvancedServiceTests |
| Organization/project administration | `admin.api` with all 124 named Admin operations; common resource groups on `admin` | Catalog route dispatch and shared transport tests |

Realtime call creation uses multipart fields with `application/sdp` for the offer and `application/json` for session configuration. The SDP answer and Location header are retained. Voice creation, content-provenance checks, skills/version creation, video creation/editing/extensions/characters, container files, and upload parts use multipart. Video object references use nested form names such as `video[id]` and `input_reference[file_id]`, matching upstream multipart encoding. Video/skill/container/agent artifact/live recording content retain binary bytes. Speech SSE uses `stream_format: sse`; multipart transcription and image editing SSE use the string field `stream=true`.

Beta agent/vault resources use `OpenAI-Beta: agents=v1`; assistants/thread resources use `assistants=v2`; ChatKit uses `chatkit_beta=v1`; beta Responses uses the query parameter `beta=true`. Checkpoint-permission and administrative operations require an appropriately authorized API key. The library sends requests only when called. It never executes tool callbacks or submits agent work automatically.

## Verification limits

`EndpointTests.testEveryPinnedOperationDispatchesItsDeclaredMethodAndEscapedPath` compares the full selector catalog with a generated fixture and sends all 340 operations through an injected recording transport. It checks method/path dispatch, fixed query defaults, and parameter escaping; it does not assert that arbitrary JSON is accepted by OpenAI for every endpoint. The separate upstream comparison script independently extracts route facts from the pinned official references. Model tests exercise wire encoding/decoding. Service tests exercise representative multipart, binary, versioned, action, and streaming contracts. Loopback integration tests validate real network transport separately.

No method/path from the six pinned REST references is unrepresented. Payload validation and rare response schemas remain server-owned or application-owned through JSONValue/Codable. Provider support, account entitlements, tool execution, WebRTC media, and live OpenAI acceptance are distinct from route coverage. Evals, legacy realtime session endpoints, and custom paths remain available as compatibility conveniences outside this inventory. WebSocket and webhook verification APIs are documented separately.

## Reproducing the comparison

From the package root, download the exact referenced revision and compare the independently extracted method/path/symbol triples:

```sh
source_dir="$(mktemp -d)"
upstream_revision=2922f3e8a846d561d85e4aabb90f017c2de10851
curl -fsSL "https://raw.githubusercontent.com/openai/openai-go/$upstream_revision/api.md" \
    -o "$source_dir/openai-go-api.md"
for family in responses realtime conversations live webhooks; do
    curl -fsSL "https://raw.githubusercontent.com/openai/openai-go/$upstream_revision/$family/api.md" \
        -o "$source_dir/openai-go-$family-api.md"
done
python3 scripts/check-endpoint-coverage.py "$source_dir"
python3 scripts/generate-endpoints.py --check
```

The first script compares against the official references. The second verifies that checked-in Swift descriptors and the route fixture match the checked-in inventory. These are separate checks: regeneration alone cannot detect a missed upstream route.

## Complete operation mapping

Every selector below is callable through `client.api`; JSON/multipart/binary/SSE dispatch is selected using the methods above. Paths are shown relative to the configured API base URL.

| HTTP | Upstream path | Swift selector |
| --- | --- | --- |
| POST | `/decisions` | `.decisionsCreate` |
| POST | `/completions` | `.completionsCreate` |
| POST | `/chat/completions` | `.chatCompletionsCreate` |
| GET | `/chat/completions/{completion_id}` | `.chatCompletionsRetrieve` |
| POST | `/chat/completions/{completion_id}` | `.chatCompletionsUpdate` |
| GET | `/chat/completions` | `.chatCompletionsList` |
| DELETE | `/chat/completions/{completion_id}` | `.chatCompletionsDelete` |
| GET | `/chat/completions/{completion_id}/messages` | `.chatCompletionsMessagesList` |
| POST | `/embeddings` | `.embeddingsCreate` |
| POST | `/files` | `.filesCreate` |
| GET | `/files/{file_id}` | `.filesRetrieve` |
| GET | `/files` | `.filesList` |
| DELETE | `/files/{file_id}` | `.filesDelete` |
| GET | `/files/{file_id}/content` | `.filesContent` |
| POST | `/images/variations` | `.imagesCreateVariation` |
| POST | `/images/edits` | `.imagesEdit` |
| POST | `/images/generations` | `.imagesGenerate` |
| POST | `/content_provenance_checks` | `.contentProvenanceChecksCreate` |
| POST | `/audio/transcriptions` | `.audioTranscriptionsCreate` |
| POST | `/audio/translations` | `.audioTranslationsCreate` |
| POST | `/audio/speech` | `.audioSpeechCreate` |
| POST | `/audio/voices` | `.audioVoicesCreate` |
| POST | `/moderations` | `.moderationsCreate` |
| GET | `/models/{model}` | `.modelsRetrieve` |
| GET | `/models` | `.modelsList` |
| DELETE | `/models/{model}` | `.modelsDelete` |
| POST | `/fine_tuning/jobs` | `.fineTuningJobsCreate` |
| GET | `/fine_tuning/jobs/{fine_tuning_job_id}` | `.fineTuningJobsRetrieve` |
| GET | `/fine_tuning/jobs` | `.fineTuningJobsList` |
| POST | `/fine_tuning/jobs/{fine_tuning_job_id}/cancel` | `.fineTuningJobsCancel` |
| GET | `/fine_tuning/jobs/{fine_tuning_job_id}/events` | `.fineTuningJobsListEvents` |
| POST | `/fine_tuning/jobs/{fine_tuning_job_id}/pause` | `.fineTuningJobsPause` |
| POST | `/fine_tuning/jobs/{fine_tuning_job_id}/resume` | `.fineTuningJobsResume` |
| GET | `/fine_tuning/jobs/{fine_tuning_job_id}/checkpoints` | `.fineTuningJobsCheckpointsList` |
| POST | `/fine_tuning/checkpoints/{fine_tuned_model_checkpoint}/permissions` | `.fineTuningCheckpointsPermissionsCreate` |
| GET | `/fine_tuning/checkpoints/{fine_tuned_model_checkpoint}/permissions` | `.fineTuningCheckpointsPermissionsRetrieve` |
| GET | `/fine_tuning/checkpoints/{fine_tuned_model_checkpoint}/permissions` | `.fineTuningCheckpointsPermissionsList` |
| DELETE | `/fine_tuning/checkpoints/{fine_tuned_model_checkpoint}/permissions/{permission_id}` | `.fineTuningCheckpointsPermissionsDelete` |
| POST | `/fine_tuning/alpha/graders/run` | `.fineTuningAlphaGradersRun` |
| POST | `/fine_tuning/alpha/graders/validate` | `.fineTuningAlphaGradersValidate` |
| POST | `/vector_stores` | `.vectorStoresCreate` |
| GET | `/vector_stores/{vector_store_id}` | `.vectorStoresRetrieve` |
| POST | `/vector_stores/{vector_store_id}` | `.vectorStoresUpdate` |
| GET | `/vector_stores` | `.vectorStoresList` |
| DELETE | `/vector_stores/{vector_store_id}` | `.vectorStoresDelete` |
| POST | `/vector_stores/{vector_store_id}/search` | `.vectorStoresSearch` |
| POST | `/vector_stores/{vector_store_id}/files` | `.vectorStoresFilesCreate` |
| GET | `/vector_stores/{vector_store_id}/files/{file_id}` | `.vectorStoresFilesRetrieve` |
| POST | `/vector_stores/{vector_store_id}/files/{file_id}` | `.vectorStoresFilesUpdate` |
| GET | `/vector_stores/{vector_store_id}/files` | `.vectorStoresFilesList` |
| DELETE | `/vector_stores/{vector_store_id}/files/{file_id}` | `.vectorStoresFilesDelete` |
| GET | `/vector_stores/{vector_store_id}/files/{file_id}/content` | `.vectorStoresFilesContent` |
| POST | `/vector_stores/{vector_store_id}/file_batches` | `.vectorStoresFileBatchesCreate` |
| GET | `/vector_stores/{vector_store_id}/file_batches/{batch_id}` | `.vectorStoresFileBatchesRetrieve` |
| POST | `/vector_stores/{vector_store_id}/file_batches/{batch_id}/cancel` | `.vectorStoresFileBatchesCancel` |
| GET | `/vector_stores/{vector_store_id}/file_batches/{batch_id}/files` | `.vectorStoresFileBatchesListFiles` |
| GET | `/safety/cases/{id}` | `.safetyCasesRetrieve` |
| GET | `/safety/alerts/{id}` | `.safetyAlertsRetrieve` |
| POST | `/agents` | `.betaAgentsCreate` |
| GET | `/agents/{agent_id}` | `.betaAgentsRetrieve` |
| POST | `/agents/{agent_id}` | `.betaAgentsUpdate` |
| GET | `/agents` | `.betaAgentsList` |
| DELETE | `/agents/{agent_id}` | `.betaAgentsDelete` |
| POST | `/agents/environments` | `.betaAgentsEnvironmentsCreate` |
| GET | `/agents/environments/{environment_id}` | `.betaAgentsEnvironmentsRetrieve` |
| GET | `/agents/environments` | `.betaAgentsEnvironmentsList` |
| POST | `/agents/environments/{environment_id}/files` | `.betaAgentsEnvironmentsFilesCreate` |
| GET | `/agents/environments/{environment_id}/files` | `.betaAgentsEnvironmentsFilesList` |
| POST | `/agents/environments/templates` | `.betaAgentsEnvironmentsTemplatesCreate` |
| GET | `/agents/environments/templates/{environment_template_id}` | `.betaAgentsEnvironmentsTemplatesRetrieve` |
| POST | `/agents/environments/templates/{environment_template_id}` | `.betaAgentsEnvironmentsTemplatesUpdate` |
| GET | `/agents/environments/templates` | `.betaAgentsEnvironmentsTemplatesList` |
| DELETE | `/agents/environments/templates/{environment_template_id}` | `.betaAgentsEnvironmentsTemplatesDelete` |
| POST | `/vaults` | `.betaAgentsVaultsCreate` |
| GET | `/vaults/{vault_id}` | `.betaAgentsVaultsRetrieve` |
| POST | `/vaults/{vault_id}` | `.betaAgentsVaultsUpdate` |
| GET | `/vaults` | `.betaAgentsVaultsList` |
| DELETE | `/vaults/{vault_id}` | `.betaAgentsVaultsDelete` |
| POST | `/vaults/{vault_id}/credentials` | `.betaAgentsVaultsCredentialsCreate` |
| GET | `/vaults/{vault_id}/credentials/{credential_id}` | `.betaAgentsVaultsCredentialsRetrieve` |
| POST | `/vaults/{vault_id}/credentials/{credential_id}` | `.betaAgentsVaultsCredentialsUpdate` |
| GET | `/vaults/{vault_id}/credentials` | `.betaAgentsVaultsCredentialsList` |
| DELETE | `/vaults/{vault_id}/credentials/{credential_id}` | `.betaAgentsVaultsCredentialsDelete` |
| POST | `/agents/sessions` | `.betaAgentsSessionsCreate` |
| GET | `/agents/sessions/{session_id}` | `.betaAgentsSessionsRetrieve` |
| POST | `/agents/sessions/{session_id}` | `.betaAgentsSessionsUpdate` |
| GET | `/agents/sessions` | `.betaAgentsSessionsList` |
| DELETE | `/agents/sessions/{session_id}` | `.betaAgentsSessionsDelete` |
| GET | `/agents/sessions/{session_id}/subagents/{subagent_id}` | `.betaAgentsSessionsSubagentsRetrieve` |
| GET | `/agents/sessions/{session_id}/subagents` | `.betaAgentsSessionsSubagentsList` |
| GET | `/agents/sessions/{session_id}/subagents/{subagent_id}/items` | `.betaAgentsSessionsSubagentsItemsList` |
| GET | `/agents/sessions/{session_id}/subagents/{subagent_id}/turns/{turn_id}` | `.betaAgentsSessionsSubagentsTurnsRetrieve` |
| GET | `/agents/sessions/{session_id}/subagents/{subagent_id}/turns` | `.betaAgentsSessionsSubagentsTurnsList` |
| GET | `/agents/sessions/{session_id}/subagents/{subagent_id}/turns/{turn_id}/items` | `.betaAgentsSessionsSubagentsTurnsItemsList` |
| GET | `/agents/sessions/{session_id}/artifacts/{artifact_id}` | `.betaAgentsSessionsArtifactsRetrieve` |
| GET | `/agents/sessions/{session_id}/artifacts` | `.betaAgentsSessionsArtifactsList` |
| DELETE | `/agents/sessions/{session_id}/artifacts/{artifact_id}` | `.betaAgentsSessionsArtifactsDelete` |
| GET | `/agents/sessions/{session_id}/artifacts/{artifact_id}/content` | `.betaAgentsSessionsArtifactsContent` |
| GET | `/agents/sessions/{session_id}/items` | `.betaAgentsSessionsItemsList` |
| POST | `/agents/sessions/{session_id}/events` | `.betaAgentsSessionsEventsCreate` |
| GET | `/agents/sessions/{session_id}/events` | `.betaAgentsSessionsEventsStream` |
| GET | `/agents/sessions/{session_id}/traces` | `.betaAgentsSessionsTracesList` |
| GET | `/agents/sessions/{session_id}/turns/{turn_id}` | `.betaAgentsSessionsTurnsRetrieve` |
| GET | `/agents/sessions/{session_id}/turns` | `.betaAgentsSessionsTurnsList` |
| GET | `/agents/sessions/{session_id}/turns/{turn_id}/items` | `.betaAgentsSessionsTurnsItemsList` |
| POST | `/responses?beta=true` | `.betaResponsesCreate` |
| GET | `/responses/{response_id}?beta=true` | `.betaResponsesRetrieve` |
| DELETE | `/responses/{response_id}?beta=true` | `.betaResponsesDelete` |
| POST | `/responses/{response_id}/cancel?beta=true` | `.betaResponsesCancel` |
| POST | `/responses/compact?beta=true` | `.betaResponsesCompact` |
| GET | `/responses/{response_id}/input_items?beta=true` | `.betaResponsesInputItemsList` |
| POST | `/responses/input_tokens?beta=true` | `.betaResponsesInputTokensCount` |
| POST | `/chatkit/sessions` | `.betaChatKitSessionsCreate` |
| POST | `/chatkit/sessions/{session_id}/cancel` | `.betaChatKitSessionsCancel` |
| GET | `/chatkit/threads/{thread_id}` | `.betaChatKitThreadsRetrieve` |
| GET | `/chatkit/threads` | `.betaChatKitThreadsList` |
| DELETE | `/chatkit/threads/{thread_id}` | `.betaChatKitThreadsDelete` |
| GET | `/chatkit/threads/{thread_id}/items` | `.betaChatKitThreadsListItems` |
| POST | `/assistants` | `.betaAssistantsCreate` |
| GET | `/assistants/{assistant_id}` | `.betaAssistantsRetrieve` |
| POST | `/assistants/{assistant_id}` | `.betaAssistantsUpdate` |
| GET | `/assistants` | `.betaAssistantsList` |
| DELETE | `/assistants/{assistant_id}` | `.betaAssistantsDelete` |
| POST | `/threads` | `.betaThreadsCreate` |
| GET | `/threads/{thread_id}` | `.betaThreadsRetrieve` |
| POST | `/threads/{thread_id}` | `.betaThreadsUpdate` |
| DELETE | `/threads/{thread_id}` | `.betaThreadsDelete` |
| POST | `/threads/runs` | `.betaThreadsCreateAndRun` |
| POST | `/threads/{thread_id}/runs` | `.betaThreadsRunsCreate` |
| GET | `/threads/{thread_id}/runs/{run_id}` | `.betaThreadsRunsRetrieve` |
| POST | `/threads/{thread_id}/runs/{run_id}` | `.betaThreadsRunsUpdate` |
| GET | `/threads/{thread_id}/runs` | `.betaThreadsRunsList` |
| POST | `/threads/{thread_id}/runs/{run_id}/cancel` | `.betaThreadsRunsCancel` |
| POST | `/threads/{thread_id}/runs/{run_id}/submit_tool_outputs` | `.betaThreadsRunsSubmitToolOutputs` |
| GET | `/threads/{thread_id}/runs/{run_id}/steps/{step_id}` | `.betaThreadsRunsStepsRetrieve` |
| GET | `/threads/{thread_id}/runs/{run_id}/steps` | `.betaThreadsRunsStepsList` |
| POST | `/threads/{thread_id}/messages` | `.betaThreadsMessagesCreate` |
| GET | `/threads/{thread_id}/messages/{message_id}` | `.betaThreadsMessagesRetrieve` |
| POST | `/threads/{thread_id}/messages/{message_id}` | `.betaThreadsMessagesUpdate` |
| GET | `/threads/{thread_id}/messages` | `.betaThreadsMessagesList` |
| DELETE | `/threads/{thread_id}/messages/{message_id}` | `.betaThreadsMessagesDelete` |
| POST | `/batches` | `.batchesCreate` |
| GET | `/batches/{batch_id}` | `.batchesRetrieve` |
| GET | `/batches` | `.batchesList` |
| POST | `/batches/{batch_id}/cancel` | `.batchesCancel` |
| POST | `/uploads` | `.uploadsCreate` |
| POST | `/uploads/{upload_id}/cancel` | `.uploadsCancel` |
| POST | `/uploads/{upload_id}/complete` | `.uploadsComplete` |
| POST | `/uploads/{upload_id}/parts` | `.uploadsPartsCreate` |
| GET | `/organization/audit_logs` | `.adminOrganizationAuditLogsList` |
| POST | `/organization/admin_api_keys` | `.adminOrganizationAdminAPIKeysCreate` |
| GET | `/organization/admin_api_keys/{key_id}` | `.adminOrganizationAdminAPIKeysRetrieve` |
| GET | `/organization/admin_api_keys` | `.adminOrganizationAdminAPIKeysList` |
| DELETE | `/organization/admin_api_keys/{key_id}` | `.adminOrganizationAdminAPIKeysDelete` |
| GET | `/organization/usage/audio_speeches` | `.adminOrganizationUsageAudioSpeeches` |
| GET | `/organization/usage/audio_transcriptions` | `.adminOrganizationUsageAudioTranscriptions` |
| GET | `/organization/usage/code_interpreter_sessions` | `.adminOrganizationUsageCodeInterpreterSessions` |
| GET | `/organization/usage/completions` | `.adminOrganizationUsageCompletions` |
| GET | `/organization/costs` | `.adminOrganizationUsageCosts` |
| GET | `/organization/usage/embeddings` | `.adminOrganizationUsageEmbeddings` |
| GET | `/organization/usage/file_search_calls` | `.adminOrganizationUsageFileSearchCalls` |
| GET | `/organization/usage/images` | `.adminOrganizationUsageImages` |
| GET | `/organization/usage/moderations` | `.adminOrganizationUsageModerations` |
| GET | `/organization/usage/vector_stores` | `.adminOrganizationUsageVectorStores` |
| GET | `/organization/usage/web_search_calls` | `.adminOrganizationUsageWebSearchCalls` |
| POST | `/organization/invites` | `.adminOrganizationInvitesCreate` |
| GET | `/organization/invites/{invite_id}` | `.adminOrganizationInvitesRetrieve` |
| GET | `/organization/invites` | `.adminOrganizationInvitesList` |
| DELETE | `/organization/invites/{invite_id}` | `.adminOrganizationInvitesDelete` |
| GET | `/organization/users/{user_id}` | `.adminOrganizationUsersRetrieve` |
| POST | `/organization/users/{user_id}` | `.adminOrganizationUsersUpdate` |
| GET | `/organization/users` | `.adminOrganizationUsersList` |
| DELETE | `/organization/users/{user_id}` | `.adminOrganizationUsersDelete` |
| POST | `/organization/users/{user_id}/roles` | `.adminOrganizationUsersRolesCreate` |
| GET | `/organization/users/{user_id}/roles/{role_id}` | `.adminOrganizationUsersRolesRetrieve` |
| GET | `/organization/users/{user_id}/roles` | `.adminOrganizationUsersRolesList` |
| DELETE | `/organization/users/{user_id}/roles/{role_id}` | `.adminOrganizationUsersRolesDelete` |
| POST | `/organization/groups` | `.adminOrganizationGroupsCreate` |
| GET | `/organization/groups/{group_id}` | `.adminOrganizationGroupsRetrieve` |
| POST | `/organization/groups/{group_id}` | `.adminOrganizationGroupsUpdate` |
| GET | `/organization/groups` | `.adminOrganizationGroupsList` |
| DELETE | `/organization/groups/{group_id}` | `.adminOrganizationGroupsDelete` |
| POST | `/organization/groups/{group_id}/users` | `.adminOrganizationGroupsUsersCreate` |
| GET | `/organization/groups/{group_id}/users/{user_id}` | `.adminOrganizationGroupsUsersRetrieve` |
| GET | `/organization/groups/{group_id}/users` | `.adminOrganizationGroupsUsersList` |
| DELETE | `/organization/groups/{group_id}/users/{user_id}` | `.adminOrganizationGroupsUsersDelete` |
| POST | `/organization/groups/{group_id}/roles` | `.adminOrganizationGroupsRolesCreate` |
| GET | `/organization/groups/{group_id}/roles/{role_id}` | `.adminOrganizationGroupsRolesRetrieve` |
| GET | `/organization/groups/{group_id}/roles` | `.adminOrganizationGroupsRolesList` |
| DELETE | `/organization/groups/{group_id}/roles/{role_id}` | `.adminOrganizationGroupsRolesDelete` |
| POST | `/organization/roles` | `.adminOrganizationRolesCreate` |
| GET | `/organization/roles/{role_id}` | `.adminOrganizationRolesRetrieve` |
| POST | `/organization/roles/{role_id}` | `.adminOrganizationRolesUpdate` |
| GET | `/organization/roles` | `.adminOrganizationRolesList` |
| DELETE | `/organization/roles/{role_id}` | `.adminOrganizationRolesDelete` |
| GET | `/organization/data_retention` | `.adminOrganizationDataRetentionRetrieve` |
| POST | `/organization/data_retention` | `.adminOrganizationDataRetentionUpdate` |
| POST | `/organization/external_storage` | `.adminOrganizationExternalStorageCreate` |
| GET | `/organization/external_storage/{external_storage_id}` | `.adminOrganizationExternalStorageRetrieve` |
| GET | `/organization/external_storage` | `.adminOrganizationExternalStorageList` |
| DELETE | `/organization/external_storage/{external_storage_id}` | `.adminOrganizationExternalStorageDelete` |
| POST | `/organization/external_storage/{external_storage_id}/validate` | `.adminOrganizationExternalStorageValidate` |
| GET | `/organization/spend_limit` | `.adminOrganizationSpendLimitRetrieve` |
| POST | `/organization/spend_limit` | `.adminOrganizationSpendLimitUpdate` |
| DELETE | `/organization/spend_limit` | `.adminOrganizationSpendLimitDelete` |
| POST | `/organization/spend_alerts` | `.adminOrganizationSpendAlertsCreate` |
| GET | `/organization/spend_alerts/{alert_id}` | `.adminOrganizationSpendAlertsRetrieve` |
| POST | `/organization/spend_alerts/{alert_id}` | `.adminOrganizationSpendAlertsUpdate` |
| GET | `/organization/spend_alerts` | `.adminOrganizationSpendAlertsList` |
| DELETE | `/organization/spend_alerts/{alert_id}` | `.adminOrganizationSpendAlertsDelete` |
| POST | `/organization/certificates` | `.adminOrganizationCertificatesCreate` |
| GET | `/organization/certificates/{certificate_id}` | `.adminOrganizationCertificatesRetrieve` |
| POST | `/organization/certificates/{certificate_id}` | `.adminOrganizationCertificatesUpdate` |
| GET | `/organization/certificates` | `.adminOrganizationCertificatesList` |
| DELETE | `/organization/certificates/{certificate_id}` | `.adminOrganizationCertificatesDelete` |
| POST | `/organization/certificates/activate` | `.adminOrganizationCertificatesActivate` |
| POST | `/organization/certificates/deactivate` | `.adminOrganizationCertificatesDeactivate` |
| POST | `/organization/projects` | `.adminOrganizationProjectsCreate` |
| GET | `/organization/projects/{project_id}` | `.adminOrganizationProjectsRetrieve` |
| POST | `/organization/projects/{project_id}` | `.adminOrganizationProjectsUpdate` |
| GET | `/organization/projects` | `.adminOrganizationProjectsList` |
| POST | `/organization/projects/{project_id}/archive` | `.adminOrganizationProjectsArchive` |
| POST | `/organization/projects/{project_id}/users` | `.adminOrganizationProjectsUsersCreate` |
| GET | `/organization/projects/{project_id}/users/{user_id}` | `.adminOrganizationProjectsUsersRetrieve` |
| POST | `/organization/projects/{project_id}/users/{user_id}` | `.adminOrganizationProjectsUsersUpdate` |
| GET | `/organization/projects/{project_id}/users` | `.adminOrganizationProjectsUsersList` |
| DELETE | `/organization/projects/{project_id}/users/{user_id}` | `.adminOrganizationProjectsUsersDelete` |
| POST | `/projects/{project_id}/users/{user_id}/roles` | `.adminOrganizationProjectsUsersRolesCreate` |
| GET | `/projects/{project_id}/users/{user_id}/roles/{role_id}` | `.adminOrganizationProjectsUsersRolesRetrieve` |
| GET | `/projects/{project_id}/users/{user_id}/roles` | `.adminOrganizationProjectsUsersRolesList` |
| DELETE | `/projects/{project_id}/users/{user_id}/roles/{role_id}` | `.adminOrganizationProjectsUsersRolesDelete` |
| POST | `/organization/projects/{project_id}/service_accounts` | `.adminOrganizationProjectsServiceAccountsCreate` |
| GET | `/organization/projects/{project_id}/service_accounts/{service_account_id}` | `.adminOrganizationProjectsServiceAccountsRetrieve` |
| POST | `/organization/projects/{project_id}/service_accounts/{service_account_id}` | `.adminOrganizationProjectsServiceAccountsUpdate` |
| GET | `/organization/projects/{project_id}/service_accounts` | `.adminOrganizationProjectsServiceAccountsList` |
| DELETE | `/organization/projects/{project_id}/service_accounts/{service_account_id}` | `.adminOrganizationProjectsServiceAccountsDelete` |
| POST | `/organization/projects/{project_id}/service_accounts/{service_account_id}/api_keys` | `.adminOrganizationProjectsServiceAccountsAPIKeysCreate` |
| GET | `/organization/projects/{project_id}/api_keys/{api_key_id}` | `.adminOrganizationProjectsAPIKeysRetrieve` |
| GET | `/organization/projects/{project_id}/api_keys` | `.adminOrganizationProjectsAPIKeysList` |
| DELETE | `/organization/projects/{project_id}/api_keys/{api_key_id}` | `.adminOrganizationProjectsAPIKeysDelete` |
| GET | `/organization/projects/{project_id}/rate_limits` | `.adminOrganizationProjectsRateLimitsListRateLimits` |
| POST | `/organization/projects/{project_id}/rate_limits/{rate_limit_id}` | `.adminOrganizationProjectsRateLimitsUpdateRateLimit` |
| GET | `/organization/projects/{project_id}/model_permissions` | `.adminOrganizationProjectsModelPermissionsRetrieve` |
| POST | `/organization/projects/{project_id}/model_permissions` | `.adminOrganizationProjectsModelPermissionsUpdate` |
| DELETE | `/organization/projects/{project_id}/model_permissions` | `.adminOrganizationProjectsModelPermissionsDelete` |
| GET | `/organization/projects/{project_id}/hosted_tool_permissions` | `.adminOrganizationProjectsHostedToolPermissionsRetrieve` |
| POST | `/organization/projects/{project_id}/hosted_tool_permissions` | `.adminOrganizationProjectsHostedToolPermissionsUpdate` |
| POST | `/organization/projects/{project_id}/groups` | `.adminOrganizationProjectsGroupsCreate` |
| GET | `/organization/projects/{project_id}/groups/{group_id}` | `.adminOrganizationProjectsGroupsRetrieve` |
| GET | `/organization/projects/{project_id}/groups` | `.adminOrganizationProjectsGroupsList` |
| DELETE | `/organization/projects/{project_id}/groups/{group_id}` | `.adminOrganizationProjectsGroupsDelete` |
| POST | `/projects/{project_id}/groups/{group_id}/roles` | `.adminOrganizationProjectsGroupsRolesCreate` |
| GET | `/projects/{project_id}/groups/{group_id}/roles/{role_id}` | `.adminOrganizationProjectsGroupsRolesRetrieve` |
| GET | `/projects/{project_id}/groups/{group_id}/roles` | `.adminOrganizationProjectsGroupsRolesList` |
| DELETE | `/projects/{project_id}/groups/{group_id}/roles/{role_id}` | `.adminOrganizationProjectsGroupsRolesDelete` |
| POST | `/projects/{project_id}/roles` | `.adminOrganizationProjectsRolesCreate` |
| GET | `/projects/{project_id}/roles/{role_id}` | `.adminOrganizationProjectsRolesRetrieve` |
| POST | `/projects/{project_id}/roles/{role_id}` | `.adminOrganizationProjectsRolesUpdate` |
| GET | `/projects/{project_id}/roles` | `.adminOrganizationProjectsRolesList` |
| DELETE | `/projects/{project_id}/roles/{role_id}` | `.adminOrganizationProjectsRolesDelete` |
| GET | `/organization/projects/{project_id}/data_retention` | `.adminOrganizationProjectsDataRetentionRetrieve` |
| POST | `/organization/projects/{project_id}/data_retention` | `.adminOrganizationProjectsDataRetentionUpdate` |
| GET | `/organization/projects/{project_id}/spend_limit` | `.adminOrganizationProjectsSpendLimitRetrieve` |
| POST | `/organization/projects/{project_id}/spend_limit` | `.adminOrganizationProjectsSpendLimitUpdate` |
| DELETE | `/organization/projects/{project_id}/spend_limit` | `.adminOrganizationProjectsSpendLimitDelete` |
| POST | `/organization/projects/{project_id}/spend_alerts` | `.adminOrganizationProjectsSpendAlertsCreate` |
| GET | `/organization/projects/{project_id}/spend_alerts/{alert_id}` | `.adminOrganizationProjectsSpendAlertsRetrieve` |
| POST | `/organization/projects/{project_id}/spend_alerts/{alert_id}` | `.adminOrganizationProjectsSpendAlertsUpdate` |
| GET | `/organization/projects/{project_id}/spend_alerts` | `.adminOrganizationProjectsSpendAlertsList` |
| DELETE | `/organization/projects/{project_id}/spend_alerts/{alert_id}` | `.adminOrganizationProjectsSpendAlertsDelete` |
| GET | `/organization/projects/{project_id}/certificates` | `.adminOrganizationProjectsCertificatesList` |
| POST | `/organization/projects/{project_id}/certificates/activate` | `.adminOrganizationProjectsCertificatesActivate` |
| POST | `/organization/projects/{project_id}/certificates/deactivate` | `.adminOrganizationProjectsCertificatesDeactivate` |
| POST | `/containers` | `.containersCreate` |
| GET | `/containers/{container_id}` | `.containersRetrieve` |
| GET | `/containers` | `.containersList` |
| DELETE | `/containers/{container_id}` | `.containersDelete` |
| POST | `/containers/{container_id}/files` | `.containersFilesCreate` |
| GET | `/containers/{container_id}/files/{file_id}` | `.containersFilesRetrieve` |
| GET | `/containers/{container_id}/files` | `.containersFilesList` |
| DELETE | `/containers/{container_id}/files/{file_id}` | `.containersFilesDelete` |
| GET | `/containers/{container_id}/files/{file_id}/content` | `.containersFilesContentRetrieve` |
| POST | `/skills` | `.skillsCreate` |
| GET | `/skills/{skill_id}` | `.skillsRetrieve` |
| POST | `/skills/{skill_id}` | `.skillsUpdate` |
| GET | `/skills` | `.skillsList` |
| DELETE | `/skills/{skill_id}` | `.skillsDelete` |
| GET | `/skills/{skill_id}/content` | `.skillsContentRetrieve` |
| POST | `/skills/{skill_id}/versions` | `.skillsVersionsCreate` |
| GET | `/skills/{skill_id}/versions/{version}` | `.skillsVersionsRetrieve` |
| GET | `/skills/{skill_id}/versions` | `.skillsVersionsList` |
| DELETE | `/skills/{skill_id}/versions/{version}` | `.skillsVersionsDelete` |
| GET | `/skills/{skill_id}/versions/{version}/content` | `.skillsVersionsContentRetrieve` |
| POST | `/videos` | `.videosCreate` |
| GET | `/videos/{video_id}` | `.videosRetrieve` |
| GET | `/videos` | `.videosList` |
| DELETE | `/videos/{video_id}` | `.videosDelete` |
| POST | `/videos/characters` | `.videosCreateCharacter` |
| GET | `/videos/{video_id}/content` | `.videosDownloadContent` |
| POST | `/videos/edits` | `.videosEdit` |
| POST | `/videos/extensions` | `.videosExtend` |
| GET | `/videos/characters/{character_id}` | `.videosGetCharacter` |
| POST | `/videos/{video_id}/remix` | `.videosRemix` |
| POST | `/conversations` | `.conversationsCreate` |
| GET | `/conversations/{conversation_id}` | `.conversationsRetrieve` |
| POST | `/conversations/{conversation_id}` | `.conversationsUpdate` |
| DELETE | `/conversations/{conversation_id}` | `.conversationsDelete` |
| POST | `/conversations/{conversation_id}/items` | `.conversationsItemsCreate` |
| GET | `/conversations/{conversation_id}/items/{item_id}` | `.conversationsItemsRetrieve` |
| GET | `/conversations/{conversation_id}/items` | `.conversationsItemsList` |
| DELETE | `/conversations/{conversation_id}/items/{item_id}` | `.conversationsItemsDelete` |
| POST | `/live/sessions` | `.liveCreate` |
| POST | `/live/sessions/{session_id}/accept` | `.liveSessionsAccept` |
| GET | `/live/sessions/{session_id}/content` | `.liveSessionsDownloadRecording` |
| POST | `/live/sessions/{session_id}/fork` | `.liveSessionsFork` |
| POST | `/live/sessions/{session_id}/hangup` | `.liveSessionsHangup` |
| POST | `/live/sessions/{session_id}/refer` | `.liveSessionsRefer` |
| POST | `/live/sessions/{session_id}/reject` | `.liveSessionsReject` |
| POST | `/realtime/client_secrets` | `.realtimeClientSecretsCreate` |
| POST | `/realtime/calls` | `.realtimeCallsCreate` |
| POST | `/realtime/calls/{call_id}/accept` | `.realtimeCallsAccept` |
| POST | `/realtime/calls/{call_id}/hangup` | `.realtimeCallsHangup` |
| POST | `/realtime/calls/{call_id}/refer` | `.realtimeCallsRefer` |
| POST | `/realtime/calls/{call_id}/reject` | `.realtimeCallsReject` |
| POST | `/realtime/translations/client_secrets` | `.realtimeTranslationsClientSecretsCreate` |
| POST | `/responses` | `.responsesCreate` |
| GET | `/responses/{response_id}` | `.responsesRetrieve` |
| DELETE | `/responses/{response_id}` | `.responsesDelete` |
| POST | `/responses/{response_id}/cancel` | `.responsesCancel` |
| POST | `/responses/compact` | `.responsesCompact` |
| GET | `/responses/{response_id}/input_items` | `.responsesInputItemsList` |
| POST | `/responses/input_tokens` | `.responsesInputTokensCount` |
| POST | `/webhook_endpoints` | `.webhooksCreate` |
| GET | `/webhook_endpoints/{webhook_endpoint_id}` | `.webhooksRetrieve` |
| POST | `/webhook_endpoints/{webhook_endpoint_id}` | `.webhooksUpdate` |
| GET | `/webhook_endpoints` | `.webhooksList` |
| DELETE | `/webhook_endpoints/{webhook_endpoint_id}` | `.webhooksDelete` |
| POST | `/webhook_endpoints/{webhook_endpoint_id}/rotate_secret` | `.webhooksRotateSecret` |
| POST | `/webhook_endpoints/{webhook_endpoint_id}/test` | `.webhooksTest` |
| GET | `/webhook_event_types` | `.webhooksEventTypesList` |
