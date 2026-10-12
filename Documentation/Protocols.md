# Protocols and authentication

All examples import the public `OpenAI` module. Endpoint and model availability depends on the server. See [Compatibility.md](Compatibility.md) for the pinned REST inventory and tested platforms.

## Responses WebSocket

A connection can carry consecutive response turns. `createResponse` sends the request fields at the top level with `type: "response.create"`; streaming is implicit, and background responses are rejected. `finalResponse()` consumes a single sequential turn and returns the server response for completed, failed, or incomplete terminal events, matching the pinned Go helper. Inspect its `status` and error fields. A protocol `error` event throws `OpenAIWebSocketError.responseTerminated` with the original event; a terminal event without a response is invalid.

```swift
import OpenAI

func answer(model: String, client: OpenAIClient) async throws -> Response {
    let connection = try await client.responses.connect()
    do {
        try await connection.createResponse(ResponseRequest(model: model, input: "Hello"))
        let response = try await connection.finalResponse()
        await connection.close()
        return response
    } catch {
        await connection.close()
        throw error
    }
}
```

Use `receiveResponseEvent()` to inspect typed Responses events, or `receive()` to route JSON events and any multiplexed streams yourself. Only one receiver may be active. `send` accepts any `Encodable & Sendable` value. Native sends and receives close the connection when cancelled; close explicitly on normal completion or when stopping early. Handshakes and messages are never retried or automatically replayed.

`WebSocketOptions` controls message size, handshake timeout, and close timeout. A zero message limit selects unlimited messages; close timeout defaults to five seconds. `abort()` immediately disposes the connection. `OpenAIWebSocketTransport` and `OpenAIWebSocketConnection` support alternate stacks and fixtures. Apple platforms use URLSession; Linux uses maintained WebSocketKit/NIO with native framing, TLS, and control-frame handling. Linux's NIO decoder limits a single frame to 4 GiB even with unlimited complete messages. Authentication, query values, API prefixes, and per-request headers come from the configured client.

`connectSession` owns one physical reader and serializes sends. Named lanes route top-level `stream_id` events; untagged and unclaimed events remain on the default receiver. Detaching a named lane returns future events for that ID to the default receiver. Cancelling one lane receive leaves the queue and reader usable. Optional `inferUntaggedResponseLanes` enables additional response-ID/FIFO inference for compatible servers; it is off by default. Session buffer limits default to unlimited and can be bounded globally by event count/bytes or per lane.

Recovery is explicit: `recover(maxAttempts:retryDelay:restore:)` opens a new connection, invalidates old lanes, and optionally restores application state. Defaults are one attempt and no delay. Failed restoration disposes the replacement connection; closing or cancelling recovery cancels its pending opening/restoration. Requests with uncertain delivery are never replayed. `ResponseWebSocketAccumulator` provides lane-bound, indexed snapshots and detailed sparse indices, while rejecting mixed lanes and events after termination.

## Realtime and WebRTC setup

Realtime uses its own JSON event schema. Audio samples belong in the protocol's base64 fields; the library does not capture or play audio.

```swift
import OpenAI

func realtimeEvent(model: String, client: OpenAIClient) async throws -> JSONValue {
    let connection = try await client.realtime.connect(model: model)
    do {
        try await connection.send(JSONValue.object([
            "type": "session.update",
            "session": ["type": "realtime", "instructions": "Be concise."],
        ]))
        let event = try await connection.receive()
        await connection.close()
        return event
    } catch {
        await connection.close()
        throw error
    }
}
```

For application-owned WebRTC peer connections, `client.realtime.createCall(sdp:session:)` sends a multipart offer with `application/sdp` and optional `application/json` parts. It returns `HTTPResponse`, preserving the SDP answer and `Location` header. Call-control helpers accept, reject, refer, or hang up calls, including empty success bodies. `createCallWithRawSDP` supports compatible servers that accept a raw SDP request. The application owns peer negotiation and media transport.

## Webhook verification

Pass the exact received HTTP bytes and headers. Parsing and reserializing JSON before verification changes the signed message. A `whsec_` secret contains base64 key bytes; another nonempty secret is treated as raw UTF-8.

```swift
import Foundation
import OpenAI

func verifiedEvent(secret: String, body: Data, headers: [String: String]) throws -> WebhookEvent {
    let verifier = try WebhookVerifier(secret: secret)
    return try verifier.unwrap(payload: body, headers: headers)
}
```

The verifier checks the webhook ID, timestamp, and HMAC-SHA256 signature using constant-time authentication. Timestamp tolerance defaults to 300 seconds, and multiple signatures support secret rotation. Header names are case-insensitive; ambiguous differently cased duplicates are rejected. `verify` authenticates without decoding, and `unwrap` preserves complete event JSON in `rawValue`. The application should persist and deduplicate webhook IDs within its delivery policy; the verifier does not host an HTTP server or track deliveries.

## Dynamic authentication and OAuth

An async bearer provider can integrate any application-owned credential source. It runs once per HTTP operation or WebSocket handshake, before network retries. An explicit Authorization header in client or request options takes precedence.

```swift
import Foundation
import OpenAI

func oauthClient(tokenURL: URL, clientID: String, clientSecret: String, apiBaseURL: URL) throws -> OpenAIClient {
    let provider = try OAuthTokenProvider(configuration: OAuthConfiguration(
        tokenURL: tokenURL,
        grant: .clientCredentials(clientID: clientID, clientSecret: clientSecret, scope: "api.responses.write")
    ))
    return OpenAIClient(configuration: ClientConfiguration(
        apiKey: nil,
        baseURL: apiBaseURL,
        accessTokenProvider: { try await provider.accessToken() }
    ))
}
```

The token URL requires HTTPS, except loopback HTTP for local fixtures. Client credentials use HTTP Basic by default, with RFC 6749 form escaping of both credentials; select `.form` when the server requires credentials in the form body. Standard OAuth token responses must contain a nonempty bearer access token and a positive finite numeric `expires_in`. The default token transport rejects every redirect; injected transports must enforce their own redirect policy.

RFC 8693 exchange supports application-supplied subject credentials, an audience/resource/scope, and optional client credentials:

```swift
import Foundation
import OpenAI

func exchangeProvider(
    tokenURL: URL,
    subjectToken: @escaping @Sendable () async throws -> String
) throws -> OAuthTokenProvider {
    try OAuthTokenProvider(configuration: OAuthConfiguration(
        tokenURL: tokenURL,
        grant: .tokenExchange(
            subjectTokenProvider: subjectToken,
            audience: "https://api.openai.com",
            scope: "api.responses.write"
        )
    ))
}
```

Choose token URL, audience, scope, and subject-token type according to the identity provider. The default subject type is the JWT URN. The subject provider runs again for each exchange/refresh; this library does not discover cloud workload credentials.

OpenAI workload identity uses the Go SDK's specific JSON exchange fields rather than a standard form. Its named factory sets the OpenAI auth endpoint and refresh defaults; the application supplies fresh cloud subject credentials:

```swift
import OpenAI

func workloadIdentityClient(
    identityProviderID: String,
    serviceAccountID: String,
    subjectToken: @escaping @Sendable () async throws -> String
) throws -> OpenAIClient {
    let provider = try OAuthTokenProvider(configuration: .openAIWorkloadIdentity(
        identityProviderID: identityProviderID,
        serviceAccountID: serviceAccountID,
        subjectTokenProvider: subjectToken,
        subjectTokenType: .jwt
    ))
    return OpenAIClient(configuration: ClientConfiguration(
        apiKey: nil,
        accessTokenProvider: { try await provider.accessToken() }
    ))
}
```

Use `.id` for an ID subject token. The JSON grant sends `identity_provider_id`, `service_account_id`, the subject token and its URN, and a nonempty optional `client_id`. It omits form-grant fields and Basic authentication. The default token URL is `https://auth.openai.com/oauth/token`, and an omitted `expires_in` defaults to 3600 seconds for this grant only, matching the pinned Go behavior. Its configuration factory uses 1200 seconds of refresh leeway.

An actor shares one refresh among concurrent callers and caches only before the refresh deadline. Standard OAuth refresh leeway defaults to 30 seconds; all grants cap leeway at half the remaining lifetime. Cache residence is capped at 24 hours by default. Cancelling one waiter does not cancel another waiter's refresh. `invalidate()` clears cached tokens, cancels the active refresh, and prevents its stale result from repopulating the cache. Token acquisition uses its own timeout/retry policy; retries default to zero. HTTP 401 responses do not automatically invalidate or replay an application request.
