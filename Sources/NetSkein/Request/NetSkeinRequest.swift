import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1

public struct NetSkeinRequest<Body: BodyState>: Sendable {
    private let client: NetSkeinClient
    private var method: HTTPMethod
    private var url: String
    private var headers: HTTPHeaders
    private var body: BodySource
    /// `nil` means no limit.
    private var maxResponseBytes: Int?
    private var timeout: TimeAmount
    private var retryPolicy: RetryPolicy?
    private var attemptMiddlewares: [any HTTPMiddleware]
    private var callMiddlewares: [any HTTPMiddleware]
    private var cachePolicy: CachePolicy?
    private let percentEncoder: PercentEncoder

    init(
        client: NetSkeinClient,
        method: HTTPMethod,
        url: String,
        headers: HTTPHeaders? = nil,
        body: BodySource = .none,
        maxResponseBytes: Int? = 10 * 1024 * 1024,
        timeout: TimeAmount = .seconds(30),
        retryPolicy: RetryPolicy? = nil,
        attemptMiddlewares: [any HTTPMiddleware] = [],
        callMiddlewares: [any HTTPMiddleware] = [],
        cachePolicy: CachePolicy? = nil,
        percentEncoder: PercentEncoder = .default,
    ) {
        self.client = client
        self.method = method
        self.url = url
        self.headers = headers ?? client.defaultHeaders
        self.body = body
        self.maxResponseBytes = maxResponseBytes
        self.timeout = timeout
        self.retryPolicy = retryPolicy
        self.attemptMiddlewares = attemptMiddlewares
        self.callMiddlewares = callMiddlewares
        self.cachePolicy = cachePolicy
        self.percentEncoder = percentEncoder
    }
}

extension NetSkeinRequest where Body == BodyAllowed {
    public init(
        client: NetSkeinClient,
        method: HTTPMethod,
        url: String,
        headers: HTTPHeaders? = nil,
        maxResponseBytes: Int? = 10 * 1024 * 1024,
        timeout: TimeAmount = .seconds(30),
        retryPolicy: RetryPolicy? = nil,
        percentEncoder: PercentEncoder = .default,
    ) {
        self.init(
            client: client,
            method: method,
            url: url,
            headers: headers,
            body: .none,
            maxResponseBytes: maxResponseBytes,
            timeout: timeout,
            retryPolicy: retryPolicy,
            percentEncoder: percentEncoder
        )
    }
}

extension NetSkeinRequest {
    @discardableResult
    public func path(_ segment: PathSegment) -> Self {
        var copy = self
        let currentURL = copy.url.trimmingCharacters(in: ["/"])
        let newSegment = segment.value.trimmingCharacters(in: ["/"])
        copy.url = "\(currentURL)/\(newSegment)"
        return copy
    }

    @discardableResult
    public func header(_ name: String, _ value: String) -> Self {
        var copy = self
        copy.headers.replaceOrAdd(name: name, value: value)
        return copy
    }

    /// Appends `items` to the URL's query, sorted by name so the same items always produce the
    /// same URL. Items already in the URL keep their place before them.
    @discardableResult
    public func query(_ items: [String: String]) -> Self {
        guard var components = URLComponents(string: url) else { return self }

        var queryItems = components.queryItems ?? []
        for (key, value) in items.sorted(by: { $0.key < $1.key }) {
            queryItems.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = queryItems

        var copy = self

        if let updatedURL = components.url?.absoluteString { copy.url = updatedURL }

        return copy
    }

    /// The largest response body ``send()`` collects into memory; a larger one fails with a
    /// `networkFailure`. Defaults to 10 MiB; `nil` removes the limit, so the whole body is held
    /// in memory however large it is.
    ///
    /// Only ``send()`` holds the whole body, so only it is limited. ``stream()``,
    /// ``stream(_:)``, ``lines(maxLineLength:)`` and
    /// ``download(toFileAtPath:resumption:onProgress:)`` read the body piece by piece and have no
    /// total limit; ``lines(maxLineLength:)`` limits each line instead.
    @discardableResult
    public func maxResponseBytes(_ bytes: Int?) -> Self {
        var copy = self
        copy.maxResponseBytes = bytes
        return copy
    }

    @discardableResult
    public func timeout(_ duration: TimeAmount) -> Self {
        var copy = self
        copy.timeout = duration
        return copy
    }

    @discardableResult
    public func retry(_ policy: RetryPolicy) -> Self {
        var copy = self
        copy.retryPolicy = policy
        return copy
    }

    /// Sets how this request uses the client's ``HTTPCache``, instead of the cache's
    /// ``HTTPCache/defaultPolicy``.
    ///
    /// ``CachePolicy/reloadIgnoringCache`` and ``CachePolicy/noStore`` also add their
    /// `Cache-Control` directive to the request, which applies even without a cache. The other
    /// policies have no effect without one.
    @discardableResult
    public func cachePolicy(_ policy: CachePolicy) -> Self {
        var copy = self
        copy.cachePolicy = policy
        return copy
    }

    /// Adds a middleware for this request only; it runs inside the client's middleware of the
    /// same scope, once per call or for every attempt (the default). See ``MiddlewareScope``.
    @discardableResult
    public func using(
        _ middleware: some HTTPMiddleware,
        per scope: MiddlewareScope = .attempt
    ) -> Self {
        var copy = self
        switch scope {
        case .call: copy.callMiddlewares.append(middleware)
        case .attempt: copy.attemptMiddlewares.append(middleware)
        }
        return copy
    }

    /// Adds a closure as a middleware for this request only.
    @discardableResult
    public func using(
        per scope: MiddlewareScope = .attempt,
        _ intercept:
            @escaping @Sendable (
                RequestHead,
                MiddlewareContext,
                HTTPMiddleware.Next
            ) async throws -> HTTPClientResponse
    ) -> Self {
        using(ClosureMiddleware(intercept), per: scope)
    }
}

extension NetSkeinRequest where Body == BodyAllowed {
    @discardableResult
    public func form(
        _ fields: [String: String]
    ) throws(NetSkeinError) -> NetSkeinRequest<BodyAttached> {
        let queryString = percentEncoder.encodeForm(fields)
        let data = Data(queryString.utf8)
        let allocator = ByteBufferAllocator()
        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)

        var copy = self
        copy.body = .bytes(buffer)
        copy.headers.replaceOrAdd(name: "Content-Type", value: "application/x-www-form-urlencoded")

        return NetSkeinRequest<BodyAttached>(
            client: copy.client,
            method: copy.method,
            url: copy.url,
            headers: copy.headers,
            body: copy.body,
            maxResponseBytes: copy.maxResponseBytes,
            timeout: copy.timeout,
            retryPolicy: copy.retryPolicy,
            attemptMiddlewares: copy.attemptMiddlewares,
            callMiddlewares: copy.callMiddlewares,
            cachePolicy: copy.cachePolicy,
            percentEncoder: copy.percentEncoder,
        )
    }

    @discardableResult
    public func json(
        _ bodyObject: some Encodable
    ) throws(NetSkeinError) -> NetSkeinRequest<BodyAttached> {
        do {
            let data = try JSONEncoder().encode(bodyObject)
            let allocator = ByteBufferAllocator()
            var buffer = allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)

            var copy = self
            copy.body = .bytes(buffer)
            copy.headers.replaceOrAdd(name: "Content-Type", value: "application/json")

            return NetSkeinRequest<BodyAttached>(
                client: copy.client,
                method: copy.method,
                url: copy.url,
                headers: copy.headers,
                body: copy.body,
                maxResponseBytes: copy.maxResponseBytes,
                timeout: copy.timeout,
                retryPolicy: copy.retryPolicy,
                attemptMiddlewares: copy.attemptMiddlewares,
                callMiddlewares: copy.callMiddlewares,
                cachePolicy: copy.cachePolicy,
                percentEncoder: copy.percentEncoder,
            )
        } catch {
            throw .custom(
                kind: .invalidPayload,
                message: "Failed to decode JSON request: \(error.localizedDescription)",
                underlyingError: error
            )
        }
    }

    @discardableResult
    public func multipart(
        _ form: MultipartForm
    ) -> NetSkeinRequest<BodyAttached> {
        var copy = self
        copy.body = .bytes(form.bytes())
        copy.headers.replaceOrAdd(
            name: "Content-Type",
            value: "multipart/form-data; boundary=\(form.boundary)"
        )

        return NetSkeinRequest<BodyAttached>(
            client: copy.client,
            method: copy.method,
            url: copy.url,
            headers: copy.headers,
            body: copy.body,
            maxResponseBytes: copy.maxResponseBytes,
            timeout: copy.timeout,
            retryPolicy: copy.retryPolicy,
            attemptMiddlewares: copy.attemptMiddlewares,
            callMiddlewares: copy.callMiddlewares,
            cachePolicy: copy.cachePolicy,
            percentEncoder: copy.percentEncoder,
        )
    }

    @discardableResult
    public func file(
        atPath path: String,
        chunkSize: Int = 64 * 1024,
        onProgress: UploadProgress? = nil
    ) throws(NetSkeinError) -> NetSkeinRequest<BodyAttached> {
        // Resolve symlinks first: attributesOfItem describes a link itself, not its target.
        // Requiring a regular file rejects directories, FIFOs (which block on open), devices,
        // sockets and broken links before the request is sent.
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedPath),
            attributes[.type] as? FileAttributeType == .typeRegular
        else {
            throw .custom(
                kind: .ioFailure,
                message: "No regular file exists at path: \(path)",
            )
        }

        guard FileManager.default.isReadableFile(atPath: path) else {
            throw .custom(
                kind: .ioFailure,
                message: "Unable to read file at path: \(path)"
            )
        }

        var copy = self
        copy.body = .file(
            path: path,
            chunkSize: chunkSize,
            onProgress: onProgress
        )
        copy.headers.replaceOrAdd(name: "Content-Type", value: "application/octet-stream")

        return NetSkeinRequest<BodyAttached>(
            client: copy.client,
            method: copy.method,
            url: copy.url,
            headers: copy.headers,
            body: copy.body,
            maxResponseBytes: copy.maxResponseBytes,
            timeout: copy.timeout,
            retryPolicy: copy.retryPolicy,
            attemptMiddlewares: copy.attemptMiddlewares,
            callMiddlewares: copy.callMiddlewares,
            cachePolicy: copy.cachePolicy,
            percentEncoder: copy.percentEncoder,
        )
    }
}

extension NetSkeinRequest where Body == BodyForbidden {
    @discardableResult
    public func dangerouslyAllowBody() -> NetSkeinRequest<BodyAllowed> {
        NetSkeinRequest<BodyAllowed>(
            client: self.client,
            method: self.method,
            url: self.url,
            headers: self.headers,
            body: self.body,
            maxResponseBytes: self.maxResponseBytes,
            timeout: self.timeout,
            retryPolicy: self.retryPolicy,
            attemptMiddlewares: self.attemptMiddlewares,
            callMiddlewares: self.callMiddlewares,
            cachePolicy: self.cachePolicy,
            percentEncoder: self.percentEncoder,
        )
    }
}

extension NetSkeinRequest where Body == BodyForbidden {
    @available(
        *,
        unavailable,
        message: "This HTTP method is forbidden from holding a request body payload."
    )
    public func form(
        _ fields: [String: String]
    ) throws(NetSkeinError) -> NetSkeinRequest<BodyAttached> {
        fatalError("Unavailable at compile time")
    }

    @available(
        *,
        unavailable,
        message: "This HTTP method is forbidden from holding a request body payload."
    )
    public func json(
        _ bodyObject: some Encodable
    ) throws(NetSkeinError) -> NetSkeinRequest<BodyAttached> {
        fatalError("Unavailable at compile time")
    }

    @available(
        *,
        unavailable,
        message: "This HTTP method is forbidden from holding a request body payload."
    )
    public func multipart(
        _ form: MultipartForm
    ) -> NetSkeinRequest<BodyAttached> {
        fatalError("Unavailable at compile time")
    }

    @available(
        *,
        unavailable,
        message: "This HTTP method is forbidden from holding a request body payload."
    )
    public func file(
        atPath path: String,
        chunkSize: Int = 64 * 1024,
        onProgress: UploadProgress? = nil
    ) throws(NetSkeinError) -> NetSkeinRequest<BodyAttached> {
        fatalError("Unavailable at compile time")
    }
}

extension NetSkeinRequest where Body == BodyAttached {
    @available(
        *,
        unavailable,
        message:
            "The request body has already been assigned. A single request configuration can only contain one body payload."
    )
    public func form(
        _ fields: [String: String]
    ) throws(NetSkeinError) -> NetSkeinRequest<BodyAttached> {
        fatalError("Unavailable at compile time")
    }

    @available(
        *,
        unavailable,
        message:
            "The request body has already been assigned. A single request configuration can only contain one body payload."
    )
    public func json(
        _ bodyObject: some Encodable
    ) throws(NetSkeinError) -> NetSkeinRequest<BodyAttached> {
        fatalError("Unavailable at compile time")
    }

    @available(
        *,
        unavailable,
        message:
            "The request body has already been assigned. A single request configuration can only contain one body payload."
    )
    public func multipart(
        _ form: MultipartForm
    ) -> NetSkeinRequest<BodyAttached> {
        fatalError("Unavailable at compile time")
    }

    @available(
        *,
        unavailable,
        message:
            "The request body has already been assigned. A single request configuration can only contain one body payload."
    )
    public func file(
        atPath path: String,
        chunkSize: Int = 64 * 1024,
        onProgress: UploadProgress? = nil

    ) throws(NetSkeinError) -> NetSkeinRequest<BodyAttached> {
        fatalError("Unavailable at compile time")
    }
}

extension NetSkeinRequest {
    /// The executor for one call. `buffered` is whether the call collects the whole body, which
    /// is what lets the cache reuse and store responses.
    private func executor(buffered: Bool) -> RequestExecutor {
        let policy = cachePolicy ?? client.cache?.defaultPolicy ?? .default
        var headers = headers
        if let directive = policy.requestDirective {
            headers.add(name: "Cache-Control", value: directive)
        }

        let responseLimit = maxResponseBytes ?? .max

        // The cache sits next to the transport, so it sees the request exactly as sent
        let cache = client.cache.map {
            CacheMiddleware(
                cache: $0,
                policy: policy,
                usesStoredResponses: buffered,
                transportDecompresses: client.transportDecompresses,
                maxResponseBytes: responseLimit
            )
        }

        var attemptStack = client.attemptMiddlewares + attemptMiddlewares
        if let cache { attemptStack.append(cache) }

        // Innermost: the cache can answer while a circuit is open, and only requests that reach
        // the network count toward opening one
        if let breaker = client.circuitBreaker {
            attemptStack.append(CircuitBreakerMiddleware(breaker: breaker))
        }

        return RequestExecutor(
            client: client,
            method: method,
            url: url,
            headers: headers,
            body: body,
            timeout: timeout,
            retryPolicy: retryPolicy ?? client.retryPolicy,
            maxResponseBytes: responseLimit,
            callMiddlewares: client.callMiddlewares + callMiddlewares,
            attemptMiddlewares: attemptStack,
        )
    }
}

extension NetSkeinRequest {
    public func send() async throws(NetSkeinError) -> NetSkeinResponse {
        try await executor(buffered: true).send()
    }

    /// Sends the request and hands each chunk of a successful response to `onChunk` as it
    /// arrives, without collecting the body in memory.
    ///
    /// ## Retries
    ///
    /// The retry policy applies only until the first chunk is handed to `onChunk`:
    ///
    /// - A connection failure, a retryable status such as `503`, or a body that fails before its
    ///   first chunk is retried like ``send()``, with the same backoff and `Retry-After` handling.
    /// - Once a chunk has been delivered, any failure is thrown instead. A retry would start the
    ///   response from the beginning and deliver the same chunks again, and only the caller
    ///   knows how to undo what it did with them. To try again, reset that state and call
    ///   `stream(_:)` again.
    ///
    /// - Parameter onChunk: Called with each chunk, the bytes received so far, and the expected
    ///   total from `Content-Length` when the server sends one.
    /// - Returns: The response status and headers.
    /// - Throws: ``NetSkeinError/badStatus(_:)`` for a response outside `200..<300`, before any
    ///   chunk is delivered. An error thrown by `onChunk` is never retried and is rethrown with
    ///   kind `clientError`. Other failures are thrown once the retry policy gives up, or as
    ///   soon as they happen after the first chunk.
    @discardableResult
    public func stream(
        _ onChunk: @escaping ChunkHandler
    ) async throws(NetSkeinError) -> (status: HTTPResponseStatus, headers: HTTPHeaders) {
        try await executor(buffered: false).stream(onChunk)
    }

    /// Sends the request and returns the response as soon as its headers arrive, with the body
    /// to be read piece by piece as it arrives:
    ///
    /// ```swift
    /// let response = try await client.get(url).stream()
    /// for try await chunk in response { … }
    /// ```
    ///
    /// This is the pull-based form of ``stream(_:)``: the loop asks for each piece, so reading
    /// keeps pace with it. See ``NetSkeinStream`` for iterating.
    ///
    /// ## Retries
    ///
    /// The retry policy applies until the headers arrive: a connection failure or a retryable
    /// status such as `503` is retried like ``send()``. Once this method returns, a failure while
    /// reading the body is thrown from the loop and never retried.
    ///
    /// The response is not cached, and the request's span ends when the headers arrive. The
    /// body has no size limit; see ``maxResponseBytes(_:)``.
    ///
    /// - Returns: The response, with its body still to be read.
    /// - Throws: ``NetSkeinError/badStatus(_:)`` for a response outside `200..<300`, or the
    ///   failure that remains once the retry policy gives up.
    public func stream() async throws(NetSkeinError) -> NetSkeinStream {
        NetSkeinStream(try await executor(buffered: false).openStream())
    }

    /// Sends the request and returns its body as lines, each delivered as soon as its line ending
    /// arrives:
    ///
    /// ```swift
    /// for try await line in try await client.get(url).lines() {
    ///     print(line)
    /// }
    /// ```
    ///
    /// Meant for line-based formats such as server-sent events, JSON Lines and log streams. A
    /// body without line endings arrives as a single line once it ends. See ``NetSkeinLines`` for
    /// how lines are split, and ``stream()`` for retries, caching and tracing, which work the same.
    ///
    /// - Parameter maxLineLength: The longest line accepted, in bytes; a longer one makes the loop
    ///   throw `invalidPayload`, so a server cannot make one endless line use unbounded memory.
    ///   Defaults to 1 MiB; `nil` removes the limit, so a line is held in memory however long it
    ///   gets.
    /// - Returns: The response, with its body still to be read.
    /// - Throws: ``NetSkeinError/badStatus(_:)`` for a response outside `200..<300`, or the
    ///   failure that remains once the retry policy gives up.
    public func lines(
        maxLineLength: Int? = 1024 * 1024
    ) async throws(NetSkeinError) -> NetSkeinLines {
        try await stream().lines(maxLineLength: maxLineLength)
    }

    public func download(
        toFileAtPath path: String,
        resumption: DownloadResumption = .disabled,
        onProgress: DownloadProgress? = nil
    ) async throws(NetSkeinError) {
        try await executor(buffered: false)
            .download(to: path, resumption: resumption, onProgress: onProgress)
    }
}
