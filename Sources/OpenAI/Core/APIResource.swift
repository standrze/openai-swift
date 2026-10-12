import Foundation

/// A list page retaining both identifier cursors and opaque continuation tokens.
public struct Page<Item: Codable & Sendable>: Codable, Sendable {
    public var data: [Item]
    public var object: String?
    public var hasMore: Bool?
    public var firstID: String?
    public var lastID: String?
    public var next: String?
    public var nextPage: String?

    public init(
        data: [Item], object: String? = "list", hasMore: Bool? = nil, firstID: String? = nil, lastID: String? = nil,
        next: String? = nil, nextPage: String? = nil
    ) {
        self.data = data
        self.object = object
        self.hasMore = hasMore
        self.firstID = firstID
        self.lastID = lastID
        self.next = next
        self.nextPage = nextPage
    }

    enum CodingKeys: String, CodingKey {
        case data, object, next
        case hasMore = "has_more"
        case firstID = "first_id"
        case lastID = "last_id"
        case nextPage = "next_page"
    }
}

/// Selects the continuation metadata and query parameter used by a list endpoint.
public enum PaginationStyle: Sendable, Equatable {
    /// Detects `next_page`, `next`, and identifier cursors. Lists without continuation metadata stop after one page.
    /// Usage, cost, and Agents environment file lists automatically use `page` tokens.
    case automatic
    /// Uses the last item's `id` as `after`; missing `has_more` continues until an empty page.
    case cursor
    /// Uses `last_id` as `after`.
    case conversationCursor
    /// Uses `next` as `after`, as used by Admin groups and role lists.
    case nextCursor
    /// Uses `next_page` or `next` as `page`, as used by usage and Agents environment file lists.
    case token
    /// Never requests another page, even if the provider includes pagination metadata.
    case singlePage
}

/// Standard deletion confirmation returned by OpenAI-compatible resources.
public struct DeletedObject: Codable, Sendable {
    public var id: String
    public var object: String?
    public var deleted: Bool

    public init(id: String, object: String? = nil, deleted: Bool) {
        self.id = id
        self.object = object
        self.deleted = deleted
    }
}

/// A schema-flexible REST resource, using the same authentication, retries, and error handling as typed services.
public struct APIResource: Sendable {
    public let client: OpenAIClient
    public let path: String
    public let defaultOptions: RequestOptions

    public init(client: OpenAIClient, path: String, defaultOptions: RequestOptions = .init()) {
        self.client = client
        self.path = path
        self.defaultOptions = defaultOptions
    }

    /// Creates a nested resource, escaping each identifier as a single path component.
    public func nested(_ id: String, _ child: String) -> APIResource {
        APIResource(
            client: client, path: path + "/" + OpenAIClient.pathComponent(id) + "/" + child,
            defaultOptions: defaultOptions
        )
    }

    public func create(_ body: JSONValue = [:], options: RequestOptions = .init()) async throws -> JSONValue {
        try await client.send(.post, path: path, body: body, options: mergedOptions(options))
    }

    public func retrieve(_ id: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await client.send(.get, path: path + "/" + OpenAIClient.pathComponent(id), options: mergedOptions(options))
    }

    /// OpenAI resources generally use POST for updates; custom endpoints may use `client.send(.patch, ...)`.
    public func update(_ id: String, body: JSONValue, options: RequestOptions = .init()) async throws -> JSONValue {
        try await client.send(
            .post, path: path + "/" + OpenAIClient.pathComponent(id), body: body, options: mergedOptions(options))
    }

    public func delete(_ id: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await client.send(
            .delete, path: path + "/" + OpenAIClient.pathComponent(id), options: mergedOptions(options))
    }

    public func list(options: RequestOptions = .init()) async throws -> Page<JSONValue> {
        try await client.send(.get, path: path, options: mergedOptions(options))
    }

    public func action(_ id: String, _ action: String, body: JSONValue = [:], options: RequestOptions = .init())
        async throws -> JSONValue
    {
        try await client.send(
            .post, path: path + "/" + OpenAIClient.pathComponent(id) + "/" + action, body: body,
            options: mergedOptions(options))
    }

    /// Iterates pages lazily. Repeated or missing continuation tokens fail instead of looping forever.
    public func all(options: RequestOptions = .init(), pagination: PaginationStyle = .automatic) -> PaginatedItems {
        PaginatedItems(resource: self, options: options, pagination: pagination)
    }

    func mergedOptions(_ overrides: RequestOptions) -> RequestOptions {
        var result = defaultOptions
        for (name, value) in overrides.headers {
            for inherited in Array(result.headers.keys) where inherited.caseInsensitiveCompare(name) == .orderedSame {
                result.headers.removeValue(forKey: inherited)
            }
            result.headers[name] = value
        }
        result.query.merge(overrides.query, uniquingKeysWith: { _, override in override })
        result.queryItems.append(contentsOf: overrides.queryItems)
        result.headerMutations.append(contentsOf: overrides.headerMutations)
        result.queryMutations.append(contentsOf: overrides.queryMutations)
        result.middleware.append(contentsOf: overrides.middleware)
        result.jsonMutations.append(contentsOf: overrides.jsonMutations)
        if let value = overrides.bodyOverride { result.bodyOverride = value }
        if let value = overrides.deadline { result.deadline = value }
        if let value = overrides.baseURL { result.baseURL = value }
        if let value = overrides.maxRetryDelay { result.maxRetryDelay = value }
        result.extraBody.merge(overrides.extraBody, uniquingKeysWith: { _, override in override })
        if let timeout = overrides.timeout { result.timeout = timeout }
        if let maxRetries = overrides.maxRetries { result.maxRetries = maxRetries }
        return result
    }
}

/// A lazy single-consumer sequence across cursor or token-paginated REST lists.
public struct PaginatedItems: AsyncSequence, Sendable {
    public typealias Element = JSONValue
    let resource: APIResource
    let options: RequestOptions
    let pagination: PaginationStyle

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(resource: resource, options: resource.mergedOptions(options), pagination: pagination)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let resource: APIResource
        var options: RequestOptions
        let pagination: PaginationStyle
        var page: [JSONValue] = []
        var index = 0
        var hasMore = true
        var seenCursors: Set<String> = []

        public mutating func next() async throws -> JSONValue? {
            try Task.checkCancellation()
            while index >= page.count {
                guard hasMore else { return nil }
                let response: Page<JSONValue> = try await resource.client.send(
                    .get, path: resource.path, options: options)
                page = response.data
                index = 0
                let nextCursor = try continuation(for: response)
                hasMore = nextCursor != nil
                if let (name, cursor) = nextCursor {
                    let current = options.queryItems.last(where: { $0.name == name })?.value ?? options.query[name]
                    guard seenCursors.insert(name + "\0" + cursor).inserted, cursor != current else {
                        throw OpenAIClientError.pagination("Repeated \(name) continuation token")
                    }
                    options.queryItems.removeAll { $0.name == name }
                    options.query[name] = cursor
                    guard !page.isEmpty else {
                        throw OpenAIClientError.pagination("Empty page advertised more results")
                    }
                }
            }
            defer { index += 1 }
            return page[index]
        }

        private func continuation(for response: Page<JSONValue>) throws -> (String, String)? {
            guard response.hasMore != false else { return nil }
            let style: PaginationStyle
            if pagination == .automatic {
                let segments = resource.path.split(separator: "/")
                let environmentFiles =
                    segments.count == 4 && segments[0] == "agents"
                    && segments[1] == "environments" && segments[3] == "files"
                let usage = resource.path == "organization/costs" || resource.path.hasPrefix("organization/usage/")
                if response.nextPage != nil || environmentFiles || usage {
                    style = .token
                } else if response.next != nil {
                    style = .nextCursor
                } else {
                    guard response.hasMore == true else { return nil }
                    style = .automatic
                }
            } else {
                style = pagination
            }

            let name: String
            let candidate: String?
            switch style {
            case .automatic:
                name = "after"
                candidate = response.lastID ?? response.data.last?["id"]?.stringValue
            case .cursor:
                name = "after"
                candidate = response.data.last?["id"]?.stringValue
            case .conversationCursor:
                name = "after"
                candidate = response.lastID
            case .nextCursor:
                name = "after"
                candidate = response.next
            case .token:
                name = "page"
                candidate = response.nextPage ?? response.next
            case .singlePage:
                return nil
            }
            if let candidate, !candidate.isEmpty { return (name, candidate) }
            if response.hasMore == true || (style == .cursor && !response.data.isEmpty) {
                throw OpenAIClientError.pagination("Missing \(name) continuation token")
            }
            return nil
        }
    }
}
