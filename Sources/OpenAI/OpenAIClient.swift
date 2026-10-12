import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// An async OpenAI-compatible REST client with resource services and injectable transport.
/// Configuration is copied at construction; individual operations use `RequestOptions`.
public struct OpenAIClient: Sendable {
    public let configuration: ClientConfiguration
    private let transport: any OpenAITransport

    public init(
        configuration: ClientConfiguration = .init(),
        transport: any OpenAITransport = URLSessionTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    /// Copies configuration while retaining the injected transport.
    public func reconfigured(_ configuration: ClientConfiguration) -> Self {
        Self(configuration: configuration, transport: transport)
    }

    public var chat: ChatService { ChatService(client: self) }
    public var completions: CompletionsService { CompletionsService(client: self) }
    public var responses: ResponsesService { ResponsesService(client: self) }
    public var models: ModelsService { ModelsService(client: self) }
    public var embeddings: EmbeddingsService { EmbeddingsService(client: self) }
    public var files: FilesService { FilesService(client: self) }
    public var images: ImagesService { ImagesService(client: self) }
    public var audio: AudioService { AudioService(client: self) }
    public var moderations: ModerationsService { ModerationsService(client: self) }
    public var batches: BatchesService { BatchesService(client: self) }
    public var fineTuning: FineTuningService { FineTuningService(client: self) }
    public var vectorStores: VectorStoresService { VectorStoresService(client: self) }
    public var uploads: UploadsService { UploadsService(client: self) }
    public var conversations: ConversationsService { ConversationsService(client: self) }
    public var assistants: APIResource { beta.assistants }
    public var threads: ThreadsService { ThreadsService(client: self) }
    public var containers: ContainersService { ContainersService(client: self) }
    public var evals: EvalsService { EvalsService(client: self) }
    public var realtime: RealtimeService { RealtimeService(client: self) }
    public var api: RESTClient { RESTClient(client: self) }
    public var admin: AdminService { AdminService(client: self) }
    public var decisions: DecisionsService { DecisionsService(client: self) }
    public var contentProvenanceChecks: ContentProvenanceChecksService { ContentProvenanceChecksService(client: self) }
    public var safety: SafetyService { SafetyService(client: self) }
    public var agents: AgentsService { AgentsService(client: self) }
    public var vaults: VaultsService { VaultsService(client: self) }
    public var chatKit: ChatKitService { ChatKitService(client: self) }
    public var skills: SkillsService { SkillsService(client: self) }
    public var videos: VideosService { VideosService(client: self) }
    public var live: LiveService { LiveService(client: self) }
    public var webhooks: WebhooksService { WebhooksService(client: self) }
    public var beta: BetaService { BetaService(client: self) }

    /// Any REST resource, including vendor extensions and future API families.
    public func resource(_ path: String) -> APIResource { APIResource(client: self, path: path) }

    /// Escapes one identifier, including slashes, without escaping endpoint separators.
    public static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: .init(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_~"))!
    }

    /// Performs a JSON request and decodes an application-owned or library response type.
    public func send<Response: Decodable & Sendable, Body: Encodable & Sendable>(
        _ method: HTTPMethod,
        path: String,
        body: Body,
        options: RequestOptions = .init()
    ) async throws -> Response {
        try decode(
            await download(method, path: path, body: body, options: accepting("application/json", options: options)))
    }

    /// Performs a bodyless JSON operation. Empty success responses decode as JSON null.
    public func send<Response: Decodable & Sendable>(
        _ method: HTTPMethod,
        path: String,
        options: RequestOptions = .init()
    ) async throws -> Response {
        try decode(await download(method, path: path, options: accepting("application/json", options: options)))
    }

    /// Returns raw response bytes and metadata for binary or application-owned protocols.
    public func download(
        _ method: HTTPMethod = .get,
        path: String,
        options: RequestOptions = .init()
    ) async throws -> HTTPResponse {
        return try await AuthenticationRetryScope.withScope(configuration: configuration, options: options) {
            let options = accepting("*/*", options: options)
            let body =
                options.extraBody.isEmpty && options.jsonMutations.isEmpty
                ? nil : try encode(JSONValue.object([:]), options: options)
            let request = try await authorizedRequest(method, path: path, body: body, options: options)
            return try await perform(request, options: options)
        }
    }

    /// Returns raw bytes after sending a JSON body, for example generated audio.
    public func download<Body: Encodable & Sendable>(
        _ method: HTTPMethod,
        path: String,
        body: Body,
        options: RequestOptions = .init()
    ) async throws -> HTTPResponse {
        return try await AuthenticationRetryScope.withScope(configuration: configuration, options: options) {
            let options = accepting("*/*", options: options)
            let data = try encode(body, options: options)
            let request = try await authorizedRequest(method, path: path, body: data, options: options)
            return try await perform(request, options: options)
        }
    }

    /// Sends original bytes with an explicit MIME type, for SDP, form encoding, or vendor protocols.
    /// Raw bytes and JSON extraBody overrides cannot be combined.
    public func request(
        _ method: HTTPMethod,
        path: String,
        data: Data? = nil,
        contentType: String? = nil,
        options: RequestOptions = .init()
    ) async throws -> HTTPResponse {
        return try await AuthenticationRetryScope.withScope(configuration: configuration, options: options) {
            let options = accepting("*/*", options: options)
            guard options.extraBody.isEmpty && options.jsonMutations.isEmpty else {
                throw OpenAIClientError.invalidConfiguration("Raw requests do not accept JSON extraBody overrides")
            }
            var request = try await authorizedRequest(method, path: path, body: data, options: options)
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            return try await perform(request, options: options)
        }
    }

    /// Returns incremental raw body bytes after validating status and retrying failed handshakes.
    /// The caller must cancel the response when stopping consumption early.
    public func streamBytes(
        _ method: HTTPMethod = .get,
        path: String,
        data: Data? = nil,
        contentType: String? = nil,
        options: RequestOptions = .init()
    ) async throws -> HTTPStreamResponse {
        return try await AuthenticationRetryScope.withScope(configuration: configuration, options: options) {
            let options = accepting("*/*", options: options)
            guard options.extraBody.isEmpty && options.jsonMutations.isEmpty else {
                throw OpenAIClientError.invalidConfiguration("Raw streams do not accept JSON extraBody overrides")
            }
            var request = try await authorizedRequest(method, path: path, body: data, options: options)
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            return try await openStream(request, options: options)
        }
    }

    /// Uploads multipart fields and files. The body is held in memory for replayable retries.
    public func upload<Response: Decodable & Sendable>(
        path: String,
        fields: [String: String],
        files: [MultipartFile],
        options: RequestOptions = .init()
    ) async throws -> Response {
        try decode(
            await uploadResponse(
                path: path, fields: fields, files: files, options: accepting("application/json", options: options)))
    }

    /// Uploads multipart content while retaining binary or plain-text response bytes.
    public func uploadResponse(
        path: String,
        fields: [String: String],
        files: [MultipartFile],
        options: RequestOptions = .init()
    ) async throws -> HTTPResponse {
        try await uploadResponse(
            path: path,
            fields: fields.sorted { $0.key < $1.key }.map { MultipartField(name: $0.key, value: $0.value) },
            files: files, options: options)
    }

    /// Uploads multipart content with ordered, repeated text fields and decodes JSON.
    public func upload<Response: Decodable & Sendable>(
        path: String,
        fields: [MultipartField],
        files: [MultipartFile],
        options: RequestOptions = .init()
    ) async throws -> Response {
        try decode(
            await uploadResponse(
                path: path, fields: fields, files: files, options: accepting("application/json", options: options)))
    }

    /// Uploads multipart content with repeated field names and retains original response bytes.
    public func uploadResponse(
        path: String,
        fields: [MultipartField],
        files: [MultipartFile],
        options: RequestOptions = .init()
    ) async throws -> HTTPResponse {
        return try await AuthenticationRetryScope.withScope(configuration: configuration, options: options) {
            let options = accepting("*/*", options: options)
            let request = try await multipartRequest(path: path, fields: fields, files: files, options: options)
            return try await perform(request, options: options)
        }
    }

    /// Opens an SSE operation with multipart input, such as image editing or audio transcription.
    public func uploadStream<Event: Decodable & Sendable>(
        path: String,
        fields: [String: String],
        files: [MultipartFile],
        options: RequestOptions = .init()
    ) async throws -> OpenAIStream<Event> {
        try await uploadStream(
            path: path,
            fields: fields.sorted { $0.key < $1.key }.map { MultipartField(name: $0.key, value: $0.value) },
            files: files,
            options: options
        )
    }

    /// Opens an SSE multipart operation preserving ordered, repeated text fields.
    public func uploadStream<Event: Decodable & Sendable>(
        path: String,
        fields: [MultipartField],
        files: [MultipartFile],
        options: RequestOptions = .init()
    ) async throws -> OpenAIStream<Event> {
        return try await AuthenticationRetryScope.withScope(configuration: configuration, options: options) {
            var request = try await multipartRequest(path: path, fields: fields, files: files, options: options)
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            return eventStream(try await openStream(request, options: options))
        }
    }

    private func multipartRequest(
        path: String, fields: [MultipartField], files: [MultipartFile], options: RequestOptions
    ) async throws -> URLRequest {
        guard options.extraBody.isEmpty && options.jsonMutations.isEmpty else {
            throw OpenAIClientError.invalidConfiguration("Use multipart fields instead of extraBody for uploads")
        }
        let multipart = try MultipartBody(fields: fields, files: files)
        var request = try await authorizedRequest(.post, path: path, body: multipart.data, options: options)
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Opens an SSE POST operation. Only failures before successful headers may be retried.
    public func stream<Event: Decodable & Sendable, Body: Encodable & Sendable>(
        path: String,
        body: Body,
        options: RequestOptions = .init()
    ) async throws -> OpenAIStream<Event> {
        return try await AuthenticationRetryScope.withScope(configuration: configuration, options: options) {
            let data = try encode(body, options: options)
            var request = try await authorizedRequest(.post, path: path, body: data, options: options)
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let response = try await openStream(request, options: options)
            return eventStream(response)
        }
    }

    /// Opens an SSE GET operation, such as retrieving a background response stream.
    public func stream<Event: Decodable & Sendable>(
        path: String,
        options: RequestOptions = .init()
    ) async throws -> OpenAIStream<Event> {
        return try await AuthenticationRetryScope.withScope(configuration: configuration, options: options) {
            var request = try await authorizedRequest(.get, path: path, body: nil, options: options)
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            return eventStream(try await openStream(request, options: options))
        }
    }

    private func accepting(_ mimeType: String, options: RequestOptions) -> RequestOptions {
        var result = options
        let hasAccept = (Array(configuration.headers.keys) + Array(options.headers.keys)).contains {
            $0.caseInsensitiveCompare("Accept") == .orderedSame
        }
        if !hasAccept { result.headers["Accept"] = mimeType }
        return result
    }

    private func decode<Response: Decodable>(_ response: HTTPResponse) throws -> Response {
        do {
            return try OpenAIJSON.decode(
                Response.self, from: response.data.isEmpty ? Data("null".utf8) : response.data)
        } catch {
            throw OpenAIClientError.decoding(String(describing: error))
        }
    }

    private func encode<Body: Encodable>(_ body: Body, options: RequestOptions) throws -> Data {
        let data = try (body as? JSONValue)?.encodedData() ?? JSONEncoder().encode(body)
        guard !options.extraBody.isEmpty || !options.jsonMutations.isEmpty else { return data }
        var value = try OpenAIJSON.decode(JSONValue.self, from: data)
        if !options.extraBody.isEmpty {
            guard var object = value.objectValue else {
                throw OpenAIClientError.invalidConfiguration("extraBody requires an object request body")
            }
            object.merge(options.extraBody, uniquingKeysWith: { _, override in override })
            value = .object(object)
        }
        for mutation in options.jsonMutations { try mutation.apply(to: &value) }
        return try value.encodedData()
    }

    private func operationTransport(_ options: RequestOptions, attempt: Int) -> any OpenAITransport {
        let restricted = OriginRestrictedTransport(
            transport: transport, origin: options.baseURL ?? configuration.baseURL)
        let base: any OpenAITransport
        if let prepare = configuration.prepareAttempt {
            base = PreparedTransport(transport: restricted, prepare: prepare, attempt: attempt)
        } else {
            base = restricted
        }
        let compatible: any OpenAITransport
        if configuration.modelRetrievalFallback {
            var prefix =
                URLComponents(url: options.baseURL ?? configuration.baseURL, resolvingAgainstBaseURL: false)?
                .percentEncodedPath ?? ""
            while prefix.hasSuffix("/") { prefix.removeLast() }
            compatible = ModelRetrievalTransport(
                transport: base, modelsPath: prefix + "/models", maxBytes: configuration.maxEventBytes)
        } else {
            compatible = base
        }
        return (configuration.middleware + options.middleware).reversed().reduce(compatible) { next, middleware in
            MiddlewareTransport(middleware: middleware, next: next)
        }
    }

    private func attemptRequest(_ request: URLRequest, attempt: Int, options: RequestOptions) async throws -> URLRequest
    {
        var request = request
        let explicit =
            options.overridesAuthorization
            || (Array(configuration.headers.keys) + Array(options.headers.keys)).contains {
                $0.lowercased() == "authorization"
            }
        if attempt > 0, !explicit, let provider = configuration.accessTokenProvider {
            let token = try await provider()
            guard !token.isEmpty, !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else {
                throw OpenAIClientError.invalidConfiguration("Invalid bearer token")
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        try options.apply(to: &request)
        let result = request
        configuration.diagnostics?(
            .request(method: result.httpMethod ?? "GET", path: result.url?.path ?? "", attempt: attempt))
        return result
    }

    private func observe(_ response: HTTPResponse, attempt: Int) {
        configuration.responseObserver?(response)
        configuration.diagnostics?(.response(status: response.statusCode, attempt: attempt))
    }

    func authorizedRequest(
        _ method: HTTPMethod, path: String, body: Data? = nil, options: RequestOptions
    ) async throws -> URLRequest {
        guard AuthenticationRetryScope.current?.beginAttempt() ?? true else {
            throw OpenAIClientError.invalidConfiguration("Authentication retry budget exhausted")
        }
        let end = try RequestDeadline.end(timeout: options.timeout ?? configuration.timeout, deadline: options.deadline)
        try Task.checkCancellation()
        var request = try makeRequest(method, path: path, body: body, options: options)
        let hasAuthorization =
            options.overridesAuthorization
            || (Array(configuration.headers.keys) + Array(options.headers.keys)).contains {
                $0.caseInsensitiveCompare("Authorization") == .orderedSame
            }
        var didAcquireToken = false
        guard
            !configuration.sharesAuthenticationRetryBudget
                || (!hasAuthorization && configuration.apiKey == nil && configuration.adminAPIKey == nil)
        else {
            throw OpenAIClientError.invalidConfiguration(
                "X.509 authentication cannot be combined with Authorization overrides")
        }
        if !hasAuthorization, let provider = configuration.accessTokenProvider {
            didAcquireToken = true
            let token = try await RequestDeadline.run(until: end) { try await provider() }
            try Task.checkCancellation()
            guard !token.isEmpty, !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else {
                throw OpenAIClientError.invalidConfiguration("Token provider returned an invalid bearer token")
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if didAcquireToken || options.deadline != nil, let end {
            guard end.timeIntervalSinceNow > 0 else { throw URLError(.timedOut) }
            request.timeoutInterval = end.timeIntervalSinceNow
        }
        try options.apply(to: &request)
        return request
    }

    func makeRequest(
        _ method: HTTPMethod, path: String, body: Data?, options: RequestOptions
    ) throws -> URLRequest {
        let timeout = options.timeout ?? configuration.timeout
        let retries = options.maxRetries ?? configuration.maxRetries
        guard timeout.isFinite, timeout >= 0,
            options.maxRetryDelay.map({ $0.isFinite && (0...86_400).contains($0) }) ?? true, retries >= 0,
            retries <= 100,
            configuration.initialRetryDelay.isFinite, configuration.initialRetryDelay >= 0,
            configuration.maxRetryDelay.isFinite, configuration.maxRetryDelay >= 0,
            configuration.maxRetryDelay <= 86_400,
            configuration.maxBufferedEvents > 0, configuration.maxEventBytes > 0
        else {
            throw OpenAIClientError.invalidConfiguration("Invalid timeout, retry budget, or stream buffer limit")
        }
        guard
            var components = URLComponents(
                url: options.baseURL ?? configuration.baseURL, resolvingAgainstBaseURL: false),
            ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
            let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil
        else {
            throw OpenAIClientError.invalidConfiguration(
                "baseURL must be an HTTP(S) URL without credentials, query, or fragment")
        }
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(":"),
            !path.contains("?"), !path.contains("#"), !path.contains("\\")
        else { throw OpenAIClientError.invalidPath(path) }
        let segments = try path.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
            guard !segment.isEmpty, let decoded = String(segment).removingPercentEncoding,
                decoded != ".", decoded != "..", !decoded.contains("\\"),
                !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw OpenAIClientError.invalidPath(path) }
            return Self.pathComponent(decoded)
        }
        var prefix = components.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        components.percentEncodedPath = prefix + "/" + segments.joined(separator: "/")
        if !options.query.isEmpty || !options.queryItems.isEmpty || !options.queryMutations.isEmpty {
            components.queryItems =
                options.query.sorted { $0.key < $1.key }.map {
                    URLQueryItem(name: $0.key, value: $0.value)
                } + options.queryItems
            var queryItems = components.queryItems ?? []
            for mutation in options.queryMutations { mutation.apply(to: &queryItems) }
            components.queryItems = queryItems
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw OpenAIClientError.invalidPath(path) }
        var request = URLRequest(url: url, timeoutInterval: timeout == 0 ? RequestDeadline.unlimitedInterval : timeout)
        request.httpMethod = method.rawValue
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("openai-swift/1.0", forHTTPHeaderField: "User-Agent")
        if let key = configuration.credential(forAPIPath: path), !key.isEmpty {
            try HeaderMutation.validate(name: "Authorization", value: "Bearer " + key)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if let organization = configuration.organization {
            try HeaderMutation.validate(name: "OpenAI-Organization", value: organization)
            request.setValue(organization, forHTTPHeaderField: "OpenAI-Organization")
        }
        if let project = configuration.project {
            try HeaderMutation.validate(name: "OpenAI-Project", value: project)
            request.setValue(project, forHTTPHeaderField: "OpenAI-Project")
        }
        for (key, value) in configuration.headers {
            try HeaderMutation.validate(name: key, value: value)
            request.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in options.headers {
            try HeaderMutation.validate(name: key, value: value)
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func perform(_ request: URLRequest, options: RequestOptions) async throws -> HTTPResponse {
        let retries = options.maxRetries ?? configuration.maxRetries
        var recoveredUnauthorized = false
        for attempt in 0...retries {
            if attempt > 0, !(AuthenticationRetryScope.current?.beginAttempt() ?? true) {
                throw OpenAIClientError.invalidConfiguration("Authentication retry budget exhausted")
            }
            try Task.checkCancellation()
            do {
                let timeout =
                    attempt == 0 && request.timeoutInterval != RequestDeadline.unlimitedInterval
                    ? request.timeoutInterval : options.timeout ?? configuration.timeout
                let end = try RequestDeadline.end(timeout: timeout, deadline: options.deadline)
                let (prepared, response) = try await RequestDeadline.run(until: end) {
                    var prepared = try await attemptRequest(request, attempt: attempt, options: options)
                    if attempt > 0 {
                        prepared.timeoutInterval = timeout == 0 ? RequestDeadline.unlimitedInterval : timeout
                    }
                    return (prepared, try await operationTransport(options, attempt: attempt).send(prepared))
                }
                observe(response, attempt: attempt)
                if (200..<300).contains(response.statusCode) { return response }
                let error = APIError(response: response)
                let invalidated = await recoverUnauthorized(
                    response, request: prepared, options: options, attempt: attempt)
                let recovered =
                    invalidated && !recoveredUnauthorized && attempt < retries
                    && (AuthenticationRetryScope.current?.reserveUnauthorizedReplay() ?? true)
                recoveredUnauthorized = recoveredUnauthorized || recovered
                guard attempt < retries, AuthenticationRetryScope.current?.canRetry ?? true,
                    shouldRetry(response, options: options) || recovered
                else { throw error }
                if !recovered { try await retryDelay(attempt, headers: response.headers, options: options) }
            } catch {
                guard attempt < retries, AuthenticationRetryScope.current?.canRetry ?? true,
                    retryableNetworkError(error)
                else { throw error }
                try await retryDelay(attempt, headers: [:], options: options)
            }
        }
        throw OpenAIClientError.invalidResponse
    }

    private func openStream(_ request: URLRequest, options: RequestOptions) async throws -> HTTPStreamResponse {
        let retries = options.maxRetries ?? configuration.maxRetries
        var recoveredUnauthorized = false
        for attempt in 0...retries {
            if attempt > 0, !(AuthenticationRetryScope.current?.beginAttempt() ?? true) {
                throw OpenAIClientError.invalidConfiguration("Authentication retry budget exhausted")
            }
            try Task.checkCancellation()
            do {
                let timeout =
                    attempt == 0 && request.timeoutInterval != RequestDeadline.unlimitedInterval
                    ? request.timeoutInterval : options.timeout ?? configuration.timeout
                let end = try RequestDeadline.end(timeout: timeout, deadline: options.deadline)
                let (prepared, received) = try await RequestDeadline.run(until: end) {
                    var prepared = try await attemptRequest(request, attempt: attempt, options: options)
                    if attempt > 0 {
                        prepared.timeoutInterval = timeout == 0 ? RequestDeadline.unlimitedInterval : timeout
                    }
                    return (prepared, try await operationTransport(options, attempt: attempt).stream(prepared))
                }
                let response = RequestDeadline.stream(received, until: end)
                observe(
                    HTTPResponse(data: Data(), statusCode: response.statusCode, headers: response.headers),
                    attempt: attempt)
                if (200..<300).contains(response.statusCode) { return response }
                let errorResponse = try await withTaskCancellationHandler {
                    defer { response.cancel() }
                    var data = Data()
                    for try await chunk in response.body {
                        // Error diagnostics are bounded; a provider cannot force unbounded accumulation.
                        data.append(chunk.prefix(max(0, configuration.maxEventBytes - data.count)))
                        if data.count >= configuration.maxEventBytes { break }
                    }
                    return HTTPResponse(data: data, statusCode: response.statusCode, headers: response.headers)
                } onCancel: {
                    response.cancel()
                }
                let invalidated = await recoverUnauthorized(
                    errorResponse, request: prepared, options: options, attempt: attempt)
                let recovered =
                    invalidated && !recoveredUnauthorized && attempt < retries
                    && (AuthenticationRetryScope.current?.reserveUnauthorizedReplay() ?? true)
                recoveredUnauthorized = recoveredUnauthorized || recovered
                guard attempt < retries, AuthenticationRetryScope.current?.canRetry ?? true,
                    shouldRetry(errorResponse, options: options) || recovered
                else {
                    throw APIError(response: errorResponse)
                }
                if !recovered { try await retryDelay(attempt, headers: errorResponse.headers, options: options) }
            } catch {
                guard attempt < retries, AuthenticationRetryScope.current?.canRetry ?? true,
                    retryableNetworkError(error)
                else { throw error }
                try await retryDelay(attempt, headers: [:], options: options)
            }
        }
        throw OpenAIClientError.invalidResponse
    }

    private func recoverUnauthorized(
        _ response: HTTPResponse, request: URLRequest, options: RequestOptions, attempt: Int
    ) async -> Bool {
        guard response.statusCode == 401,
            !options.overridesAuthorization,
            !configuration.headers.keys.contains(where: { $0.lowercased() == "authorization" }),
            let authorization = request.value(forHTTPHeaderField: "Authorization"), authorization.hasPrefix("Bearer "),
            let refresh = configuration.refreshUnauthorized
        else { return false }
        let invalidated = await refresh(String(authorization.dropFirst(7)))
        return invalidated
            && (request.httpBody == nil || (configuration.middleware.isEmpty && options.middleware.isEmpty))
    }

    private func shouldRetry(_ response: HTTPResponse, options: RequestOptions) -> Bool {
        HTTPRetryPolicy.shouldRetry(status: response.statusCode, headers: response.headers)
            && ((try? HTTPRetryPolicy.decision(
                attempt: 0, headers: response.headers,
                configuration: configuration, maxDelay: options.maxRetryDelay
            ).shouldRetry) ?? false)
    }

    private func retryableNetworkError(_ error: any Error) -> Bool {
        HTTPRetryPolicy.shouldRetry(error: error)
    }

    private func retryDelay(_ attempt: Int, headers: [String: String], options: RequestOptions) async throws {
        let decision = try HTTPRetryPolicy.decision(
            attempt: attempt, headers: headers,
            configuration: configuration, maxDelay: options.maxRetryDelay)
        try Task.checkCancellation()
        if decision.delay > 0 {
            try await RequestDeadline.run(until: options.deadline) {
                try await Task.sleep(for: .seconds(decision.delay))
            }
        }
    }

    private func eventStream<Event: Decodable & Sendable>(_ response: HTTPStreamResponse) -> OpenAIStream<Event> {
        let pair = AsyncThrowingStream<Event, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(configuration.maxBufferedEvents)
        )
        let continuation = pair.continuation
        let cancellation = CancellationHandle(response.cancel)
        let task = Task {
            await withTaskCancellationHandler {
                defer { cancellation.cancel() }
                do {
                    var parser = SSEParser(maxEventBytes: configuration.maxEventBytes)
                    var sawEvent = false
                    var requiresTerminal = false
                    var sawTerminal = false
                    var observedChoices: Set<Int64> = []
                    var finishedChoices: Set<Int64> = []
                    func emit(_ event: ServerSentEvent) throws -> Bool {
                        if event.data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { return true }
                        let data = Data(event.data.utf8)
                        if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                            if (value["error"] != nil && value["error"] != .null) || event.event == "error"
                                || value["type"]?.stringValue == "error"
                            {
                                throw APIError(
                                    response: HTTPResponse(
                                        data: data, statusCode: response.statusCode, headers: response.headers))
                            }
                            if value["object"]?.stringValue == "chat.completion.chunk" {
                                requiresTerminal = true
                                for choice in value["choices"]?.arrayValue ?? [] {
                                    if let index = choice["index"]?.intValue {
                                        observedChoices.insert(index)
                                        if choice["finish_reason"] != nil && choice["finish_reason"] != .null {
                                            finishedChoices.insert(index)
                                        }
                                    }
                                }
                                sawTerminal = !observedChoices.isEmpty && observedChoices.isSubset(of: finishedChoices)
                            }
                            if let type = value["type"]?.stringValue, type.hasPrefix("response.") {
                                requiresTerminal = true
                                if ["response.completed", "response.failed", "response.incomplete"].contains(type) {
                                    sawTerminal = true
                                }
                            }
                        }
                        let value: Event
                        do { value = try OpenAIJSON.decode(Event.self, from: data) } catch {
                            throw OpenAIClientError.decoding(String(describing: error))
                        }
                        switch continuation.yield(value) {
                        case .dropped: throw OpenAIClientError.streamOverflow
                        case .terminated: throw CancellationError()
                        case .enqueued: break
                        @unknown default: throw OpenAIClientError.invalidStream("Unknown stream buffer state")
                        }
                        return false
                    }
                    for try await chunk in response.body {
                        try Task.checkCancellation()
                        for event in try parser.append(chunk) {
                            sawEvent = true
                            if try emit(event) {
                                continuation.finish()
                                return
                            }
                        }
                    }
                    for event in try parser.finish() {
                        sawEvent = true
                        if try emit(event) { break }
                    }
                    guard sawEvent else {
                        throw OpenAIClientError.invalidStream("Connection closed without an SSE event")
                    }
                    guard !requiresTerminal || sawTerminal else {
                        throw OpenAIClientError.invalidStream("Connection closed before a terminal model event")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            } onCancel: {
                cancellation.cancel()
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
            cancellation.cancel()
        }
        return OpenAIStream(
            pair.stream,
            response: HTTPResponse(data: Data(), statusCode: response.statusCode, headers: response.headers),
            cancel: {
                task.cancel()
                cancellation.cancel()
                continuation.finish(throwing: CancellationError())
            })
    }
}
