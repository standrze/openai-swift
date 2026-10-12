# Provider and transport integrations

All provider behavior is distinct from a server's supported endpoints. Fixtures validate authentication and cloud-provider protocols; no live hosted OpenAI, Azure, GCP, Kubernetes cluster, or AWS account was used. Local Ollama inference is separately verified in [LiveOllama.md](LiveOllama.md).

## Azure

`AzureOpenAI.client(endpoint:apiVersion:apiKey:tokenProvider:deploymentName:deployment:)` isolates ambient OpenAI settings. Supply exactly one credential mode. A token callback can use the application's existing Azure credential SDK. JSON inference routes use the model-to-deployment mapping, and every request includes `api-version`. Multipart media operations extract the `model` text field without decoding binary file parts; `deploymentName` can override that routing model. The factory uses a redirect-rejecting transport by default. This covers the deployment-based Azure API, not every Azure API dialect.

## AWS Bedrock

The independent `Integrations/Bedrock` Swift package exports `OpenAIBedrock`, using the official AWS SDK for Swift's default credential chain, profile resolver, and native SigV4 signer. Keeping this integration separate avoids adding AWS's native runtime to ordinary OpenAI/Ollama consumers.

```swift
import OpenAIBedrock

func bedrockModels() async throws {
    let client = try await BedrockClient.make(region: "us-west-2")
    print(try await client.models.list().data.map(\.id))
}
```

The default endpoint is `https://bedrock-mantle.REGION.api.aws/openai/v1`. Region defaults use AWS environment/config resolution; explicitly selected profiles resolve region through the pinned AWS SDK's shared-configuration parser. This uses its `FileBasedConfig` SPI under an exact SDK pin, alongside its public credential and signing APIs. Explicit resolver and bearer modes are mutually exclusive. `AWS_BEARER_TOKEN_BEDROCK` and `AWS_BEDROCK_BASE_URL` are supported. OpenAI credentials, organization, project, and base URL are not inherited. Complete serialized requests are signed again on every HTTP attempt with service `bedrock-mantle`; response SSE remains incremental. Redirects are rejected. Profile/SSO/assume-role/metadata acquisition is delegated to AWS's SDK and has not been exercised against a live account.

## Workload identity

`CloudSubjectTokens.kubernetes(fileURL:)` rereads a bounded projected-token file on refresh. `azureManagedIdentity` and `googleCloudIdentity` use the fixed link-local IPv4 metadata origin, a separate proxy-free native transport, five-second total resource timeout, bounded response bodies, and redirect rejection. GCP checks the response's `Metadata-Flavor`. These closures feed `OAuthConfiguration.openAIWorkloadIdentity`; select `.id` for GCP and `.jwt` for Kubernetes/Azure.

`ClientConfiguration.authenticate(using:)` attaches a shared `OAuthTokenProvider`. HTTP 401 recovery invalidates only the rejected cached generation and uses the normal retry budget. At most one unauthorized recovery is attempted, and body-bearing requests with middleware are not replayed for recovery. Explicit Authorization headers are respected. WebSocket opening can recover one rejected token before messages are sent.

## Native client certificates and X.509

`TLSClientIdentity(pkcs12:password:trustRootsDER:)` imports a static certificate/private key through Apple's Security framework. On macOS, it requires macOS 15's in-memory import and never intentionally writes to the user's keychain. Other Apple deployment minimums remain those in the manifest. Custom trust roots are local to this identity's transport and do not modify system trust. Linux client certificate support needs a separate native transport and is not provided by this Security-based identity type.

`URLSessionTransport(clientIdentity:)` and `URLSessionWebSocketTransport(clientIdentity:)` present this identity using native TLS challenges. `X509WorkloadIdentity` seals that transport to the global mTLS issuer and API, obtains short-lived tokens, rejects redirects/proxies, and supplies the same identity to Responses/Realtime sockets. It accepts neither arbitrary TLS callbacks nor arbitrary transport injection. `close()` rejects new admissions while already admitted operations may finish; rotation constructs a new identity/capability. Certificate enrollment and actual validity are enforced by the issuer/TLS handshake.

The OAuth actor keeps up to 1,024 issued token generations until expiry, rejects reissued rejected values, and preserves a newer cached token when an older request receives 401. `refreshFailureCooldown` optionally permits an unexpired, unrejected cached token during transient proactive refresh failures; X.509 uses a five-second cooldown, capped at half the remaining token lifetime. Authentication failures and expired or rejected tokens cannot use that fallback.

This is a Swift static-identity capability. Native application-owned identities can use platform hardware keys, while arbitrary Go crypto signers and transport-template attestation are not implemented. Issued/rejected-token history retains SHA-256 digests, with the Go limit of 1,024 live generations. X.509 parsing rejects duplicate fields, noninteger lifetimes, and malformed bearer values; issuer errors redact all response content. Proactive fallback is capped at five seconds or half the remaining lifetime. Each logical X.509 operation shares one retry budget between issuer attempts, API attempts, and a single unauthorized replay. Exchanges use at most three attempts with 25 ms initial backoff; caller deadlines replace the default 30-second whole-exchange deadline. Followers retain their own retry budgets after a shared failure. A 401 invalidates the rejected generation even when no replay budget remains. Admission survives a later capability close, and dispatch verifies that the bearer was issued by that capability. Live mTLS issuer enrollment and certificate-authenticated WebSocket upgrades have not been tested.

`OpenAIAPI.Client(x509:)` uses the same sealed capability through
`FacadeTransportAdapter`. It preserves generated model decoding and incremental
responses; request bodies are collected for URLRequest dispatch. Generic adapter
users can set `maxRequestBytes` to bound that collection.

## Platform WebSockets

Apple platforms use URLSession's native WebSocket/TLS stack. Linux uses exact
pins of WebSocketKit 2.16.2, SwiftNIO 2.103.0, and NIOSSL 2.36.1 because the tested
Swift 6.4 FoundationNetworking WebSocket backend failed binary, fragmentation,
and upgrade-status fixtures. NIO owns framing, masking, aggregation, control
frames, upgrade validation, and system-root TLS verification. Redirected upgrades
are rejected. The additional dependency graph is selected only on Linux hosts.

## Configuration and final destinations

The default OpenAI configuration reads `OPENAI_API_KEY`, `OPENAI_ADMIN_KEY`,
`OPENAI_ORG_ID`, `OPENAI_PROJECT_ID`, `OPENAI_BASE_URL`, and
`OPENAI_WEBHOOK_SECRET`. Administration routes select the admin credential;
ordinary inference routes select the API key. Explicit Authorization overrides
remain available except on the sealed X.509 capability. Ollama, Azure, Bedrock,
and X.509 factories isolate ambient OpenAI settings.

`client.webhooks.verifySignature` and `unwrap` use the configured webhook secret
or an explicit per-call secret. Both HTTP client stacks validate the final origin
after caller middleware and signing. A per-operation base URL establishes the
allowed origin for that operation.
