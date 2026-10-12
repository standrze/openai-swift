import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Immutable client defaults. The base URL includes the API prefix, usually `/v1`.
public struct ClientConfiguration: Sendable {
    /// On a namespaced model-detail 404, look up its advertised metadata in /models.
    /// Ollama's detail route rejects escaped slashes. Its factory enables this workaround; other clients default to false.
    /// Applies to resource helpers, raw REST calls, and generated clients using openAIConfiguration.
    public var modelRetrievalFallback = false
    /// Shares workload identity issuer retries with the operation's HTTP retry budget.
    public var sharesAuthenticationRetryBudget = false
    public var webSocketTransport: (any OpenAIWebSocketTransport)?
    public var middleware: [any ClientMiddleware] = []
    public var refreshUnauthorized: (@Sendable (String) async -> Bool)?
    public var responseObserver: (@Sendable (HTTPResponse) -> Void)?
    public var diagnostics: (@Sendable (ClientDiagnostic) -> Void)?
    public var prepareAttempt: (@Sendable (URLRequest, Int) async throws -> URLRequest)?
    public var apiKey: String?
    public var adminAPIKey: String?
    public var webhookSecret: String?
    /// Resolves a bearer token for each operation. Explicit Authorization headers take precedence.
    public var accessTokenProvider: (@Sendable () async throws -> String)?
    public var baseURL: URL
    public var organization: String?
    public var project: String?
    public var headers: [String: String]
    /// Per-attempt deadline in seconds, including authentication and the body. Zero disables SDK deadlines.
    public var timeout: TimeInterval
    /// Retries after the initial attempt. Streams are never replayed after successful headers.
    public var maxRetries: Int
    public var initialRetryDelay: TimeInterval
    public var maxRetryDelay: TimeInterval {
        didSet { maxServerRetryDelay = maxRetryDelay }
    }
    /// Server-directed retry waits above this limit return the original failure without retrying early.
    public var maxServerRetryDelay: TimeInterval
    /// A slow consumer fails explicitly when this event buffer is full.
    public var maxBufferedEvents: Int
    public var maxEventBytes: Int

    public init(
        apiKey: String? = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
        baseURL: URL = ClientConfiguration.environmentBaseURL,
        organization: String? = ProcessInfo.processInfo.environment["OPENAI_ORG_ID"],
        project: String? = ProcessInfo.processInfo.environment["OPENAI_PROJECT_ID"],
        headers: [String: String] = [:],
        timeout: TimeInterval = 0,
        maxRetries: Int = 2,
        initialRetryDelay: TimeInterval = 0.5,
        maxRetryDelay: TimeInterval? = nil,
        maxBufferedEvents: Int = 256,
        maxEventBytes: Int = 8 * 1024 * 1024,
        accessTokenProvider: (@Sendable () async throws -> String)? = nil,
        adminAPIKey: String? = ProcessInfo.processInfo.environment["OPENAI_ADMIN_KEY"],
        webhookSecret: String? = ProcessInfo.processInfo.environment["OPENAI_WEBHOOK_SECRET"]
    ) {
        self.apiKey = apiKey
        self.adminAPIKey = adminAPIKey
        self.webhookSecret = webhookSecret
        self.accessTokenProvider = accessTokenProvider
        self.baseURL = baseURL
        self.organization = organization
        self.project = project
        self.headers = headers
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.initialRetryDelay = initialRetryDelay
        self.maxRetryDelay = maxRetryDelay ?? 8
        self.maxServerRetryDelay = maxRetryDelay ?? 120
        self.maxBufferedEvents = maxBufferedEvents
        self.maxEventBytes = maxEventBytes
    }

    /// Reads OPENAI_BASE_URL without silently falling back to a hosted URL when it is malformed.
    public static var environmentBaseURL: URL {
        guard let address = ProcessInfo.processInfo.environment["OPENAI_BASE_URL"] else {
            return URL(string: "https://api.openai.com/v1")!
        }
        return URL(string: address) ?? URL(fileURLWithPath: address)
    }

    /// Connects to Ollama's OpenAI compatibility layer without inheriting cloud credentials.
    public static func ollama(baseURL: URL = URL(string: "http://localhost:11434/v1")!) -> Self {
        var configuration = Self(
            apiKey: nil, baseURL: baseURL, organization: nil, project: nil, adminAPIKey: nil, webhookSecret: nil)
        configuration.modelRetrievalFallback = true
        return configuration
    }

    /// Selects the credential declared by the pinned API's security scheme.
    public func credential(forAPIPath path: String) -> String? {
        let parts = path.split(separator: "?").first?.split(separator: "/").map(String.init) ?? []
        let admin =
            parts.first == "organization"
            || (parts.first == "projects" && parts.count >= 3
                && (parts[2] == "roles"
                    || (parts.count >= 5 && ["groups", "users"].contains(parts[2]) && parts[4] == "roles")))
        return admin ? adminAPIKey : apiKey
    }
}

/// Overrides client defaults for one operation. Extra body fields can explicitly send JSON null.
public struct RequestOptions: Sendable {
    public var headerMutations: [HeaderMutation] = []
    public var queryMutations: [QueryMutation] = []
    public var bodyOverride: RequestBodyOverride?
    /// Absolute deadline shared by authentication, retries, waits, and response body consumption.
    public var deadline: Date?
    public var baseURL: URL?
    public var maxRetryDelay: TimeInterval?

    public var headers: [String: String]
    public var query: [String: String]
    /// Additional query items, including repeated names; appended after dictionary query values.
    public var queryItems: [URLQueryItem]
    public var middleware: [any ClientMiddleware] = []
    public var jsonMutations: [JSONMutation] = []
    public var extraBody: [String: JSONValue]
    public var timeout: TimeInterval?
    public var maxRetries: Int?

    public init(
        headers: [String: String] = [:],
        query: [String: String] = [:],
        extraBody: [String: JSONValue] = [:],
        timeout: TimeInterval? = nil,
        maxRetries: Int? = nil,
        queryItems: [URLQueryItem] = []
    ) {
        self.headers = headers
        self.query = query
        self.queryItems = queryItems
        self.extraBody = extraBody
        self.timeout = timeout
        self.maxRetries = maxRetries
    }
}

/// HTTP verbs accepted by the generic REST interface.
public enum HTTPMethod: String, Codable, Sendable, Hashable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
    case options = "OPTIONS"
}
