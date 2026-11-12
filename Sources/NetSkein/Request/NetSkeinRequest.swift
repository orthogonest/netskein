import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1

/// A request being described, ready to be sent with ``send()`` or one of the streaming methods.
///
/// You get a request from a client method such as ``NetSkeinClient/get(_:)``, then chain methods
/// that each return a changed copy:
///
/// ```swift
/// let response = try await client.post("https://api.example.com")
///     .path("users")
///     .header("Authorization", "Bearer \(token)")
///     .json(NewUser(name: "Ada"))
///     .send()
/// ```
///
/// Because each method returns a copy, you can keep a partly built request and send variations
/// of it.
///
/// ### Bodies Checked at Compile Time
///
/// `Body` records whether the request can take a body, so mistakes don't compile:
///
/// - ``BodyForbidden``: `GET` and `DELETE` requests. Methods such as ``json(_:)`` are
///   unavailable.
/// - ``BodyAllowed``: `POST`, `PUT`, `PATCH` and ``NetSkeinClient/request(_:url:)``. Attaching
///   a body moves the request to ``BodyAttached``.
/// - ``BodyAttached``: the body is set, so attaching a second one is unavailable.
///
/// ## Topics
///
/// ### Creating a Request
///
/// - ``init(client:method:url:headers:maxResponseBytes:attemptTimeout:retryPolicy:percentEncoder:)``
///
/// ### Building the URL
///
/// - ``path(_:)``
/// - ``query(_:)``
///
/// ### Setting Headers
///
/// - ``header(_:_:)``
///
/// ### Attaching a Body
///
/// - ``json(_:)``
/// - ``form(_:)``
/// - ``multipart(_:)``
/// - ``file(atPath:chunkSize:onProgress:)``
/// - ``dangerouslyAllowBody()``
///
/// ### Sending
///
/// - ``send()``
/// - ``maxResponseBytes(_:)``
///
/// ### Streaming and Downloading
///
/// - ``stream()``
/// - ``stream(_:)``
/// - ``lines(maxLineLength:)``
/// - ``download(toFileAtPath:resumption:onProgress:)``
///
/// ### Timeouts
///
/// - ``callTimeout(_:)``
/// - ``attemptTimeout(_:)``
///
/// ### Retries and Caching
///
/// - ``retry(_:)``
/// - ``cachePolicy(_:)``
///
/// ### Middleware
///
/// - ``using(_:per:)``
/// - ``using(per:_:)``
public struct NetSkeinRequest<Body: BodyState>: Sendable {
    private let client: NetSkeinClient
    private var method: HTTPMethod
    private var url: String
    /// Starts as the client's default headers, so ``header(_:_:)`` can replace them.
    private var headers: HTTPHeaders
    private var body: BodySource
    /// `nil` means no limit.
    private var maxResponseBytes: Int?
    /// `nil` means no limit on the call as a whole.
    private var callTimeout: TimeAmount?
    private var attemptTimeout: TimeAmount
    /// `nil` uses the client's policy.
    private var retryPolicy: RetryPolicy?
    private var attemptMiddlewares: [any HTTPMiddleware]
    private var callMiddlewares: [any HTTPMiddleware]
    /// `nil` uses the cache's ``HTTPCache/defaultPolicy``.
    private var cachePolicy: CachePolicy?
    private let percentEncoder: PercentEncoder

    init(
        client: NetSkeinClient,
        method: HTTPMethod,
        url: String,
        headers: HTTPHeaders? = nil,
        body: BodySource = .none,
        maxResponseBytes: Int? = 10 * 1024 * 1024,
        callTimeout: TimeAmount?? = nil,
        attemptTimeout: TimeAmount = .seconds(30),
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
        self.callTimeout = callTimeout ?? client.callTimeout
        self.attemptTimeout = attemptTimeout
        self.retryPolicy = retryPolicy
        self.attemptMiddlewares = attemptMiddlewares
        self.callMiddlewares = callMiddlewares
        self.cachePolicy = cachePolicy
        self.percentEncoder = percentEncoder
    }
}

extension NetSkeinRequest where Body == BodyAllowed {
    /// Creates a request for any method directly, without the client's request methods.
    ///
    /// Prefer ``NetSkeinClient/request(_:url:)`` and the other client methods, which also apply the
    /// client's settings, such as its ``NetSkeinClientBuilder/callTimeout(_:)``. This initializer
    /// uses the defaults listed below instead.
    ///
    /// - Parameters:
    ///   - client: The client that sends the request.
    ///   - method: The HTTP method.
    ///   - url: The full URL, including the scheme.
    ///   - headers: The headers to send (default: `nil`). `nil` uses the client's default
    ///     headers.
    ///   - maxResponseBytes: The largest response body ``send()`` accepts (default: 10 MiB).
    ///     See ``maxResponseBytes(_:)``.
    ///   - attemptTimeout: The limit for each attempt (default: 30 seconds). See
    ///     ``attemptTimeout(_:)``.
    ///   - retryPolicy: How the request is retried (default: `nil`). `nil` uses the client's
    ///     policy. See ``retry(_:)``.
    ///   - percentEncoder: Encodes ``form(_:)`` bodies (default: ``PercentEncoder/default``).
    public init(
        client: NetSkeinClient,
        method: HTTPMethod,
        url: String,
        headers: HTTPHeaders? = nil,
        maxResponseBytes: Int? = 10 * 1024 * 1024,
        attemptTimeout: TimeAmount = .seconds(30),
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
            attemptTimeout: attemptTimeout,
            retryPolicy: retryPolicy,
            percentEncoder: percentEncoder
        )
    }
}

extension NetSkeinRequest {
    /// Appends `segment` to the URL's path, with a single `/` between them.
    ///
    /// Values you interpolate into the segment are percent-encoded, so a value can't add path
    /// components or a query of its own:
    ///
    /// ```swift
    /// client.get("https://api.example.com")
    ///     .path("users/\(username)")  // "a/b" becomes "a%2Fb"
    /// ```
    ///
    /// See ``PathSegment`` for which values are encoded. Call ``path(_:)`` before ``query(_:)``:
    /// the URL is treated as text, so a segment added after a query lands inside it.
    ///
    /// - Parameter segment: The path to append, such as `"users/\(id)"`.
    /// - Returns: A copy of the request with the longer path.
    @discardableResult
    public func path(_ segment: PathSegment) -> Self {
        var copy = self
        let currentURL = copy.url.trimmingCharacters(in: ["/"])
        let newSegment = segment.value.trimmingCharacters(in: ["/"])
        copy.url = "\(currentURL)/\(newSegment)"
        return copy
    }

    /// Sets the header `name` to `value`, replacing any value it had, including a default from
    /// ``NetSkeinClientBuilder/defaultHeaders(_:)``.
    ///
    /// - Parameters:
    ///   - name: The header name, such as `Authorization`. Names are case-insensitive.
    ///   - value: The header value.
    /// - Returns: A copy of the request with the header set.
    @discardableResult
    public func header(_ name: String, _ value: String) -> Self {
        var copy = self
        copy.headers.replaceOrAdd(name: name, value: value)
        return copy
    }

    /// Appends `items` to the URL's query, sorted by name so the same items always produce the
    /// same URL. Items already in the URL keep their place before them.
    ///
    /// - Parameter items: The query items to add, by name.
    /// - Returns: A copy of the request with the longer query.
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

    /// The largest response body ``send()`` collects into memory (default: 10 MiB). A larger one
    /// fails with a `networkFailure`. `nil` removes the limit, so the whole body is held in
    /// memory however large it is.
    ///
    /// Only ``send()`` holds the whole body, so only it is limited. ``stream()``,
    /// ``stream(_:)``, ``lines(maxLineLength:)`` and
    /// ``download(toFileAtPath:resumption:onProgress:)`` read the body piece by piece and have no
    /// total limit. ``lines(maxLineLength:)`` limits each line instead.
    ///
    /// - Parameter bytes: The largest body accepted, in bytes. `nil` for no limit.
    /// - Returns: A copy of the request with the new limit.
    @discardableResult
    public func maxResponseBytes(_ bytes: Int?) -> Self {
        var copy = self
        copy.maxResponseBytes = bytes
        return copy
    }

    /// Limits the whole call: every attempt, the waits between them, and reading the body.
    ///
    /// When the limit passes, the call is cancelled and fails with
    /// ``NetSkeinError/Kind/timedOut``. Before waiting for a retry that would end after the limit,
    /// the call stops instead and returns or throws what the last attempt produced. For
    /// ``stream()`` and ``lines(maxLineLength:)``, which return once the headers arrive, the limit
    /// ends there. Iterating the body afterwards is not limited by it.
    ///
    /// `nil`, the default unless the client sets one, puts no limit on the call as a whole. Each
    /// attempt is still limited by ``attemptTimeout(_:)``, and each wait for body data by the
    /// client's read timeout, but retries and a slowly arriving body can make the total much
    /// longer. Set it when the caller has a time budget. Pass `nil` to remove the client's limit
    /// for this request.
    ///
    /// - Parameter duration: The longest the whole call can take. `nil` for no limit.
    /// - Returns: A copy of the request with the new call timeout.
    @discardableResult
    public func callTimeout(_ duration: TimeAmount?) -> Self {
        var copy = self
        copy.callTimeout = duration
        return copy
    }

    /// Limits each attempt, from sending the request until the response headers arrive
    /// (default: 30 seconds).
    ///
    /// It starts over for every retry and does not cover reading the body, which the client's
    /// read timeout limits instead. Raise it for servers that take long to start answering, such
    /// as long polling. See ``callTimeout(_:)`` to limit the whole call.
    ///
    /// - Parameter duration: The longest each attempt can wait for response headers.
    /// - Returns: A copy of the request with the new attempt timeout.
    @discardableResult
    public func attemptTimeout(_ duration: TimeAmount) -> Self {
        var copy = self
        copy.attemptTimeout = duration
        return copy
    }

    @available(
        *,
        unavailable,
        message: "Use callTimeout(_:) for the whole call, or attemptTimeout(_:) for each attempt"
    )
    public func timeout(_ duration: TimeAmount) -> Self {
        fatalError("Unavailable at compile time")
    }

    /// Sets how this request is retried when it fails, instead of the client's
    /// ``NetSkeinClientBuilder/retryPolicy(_:)``.
    ///
    /// - Parameter policy: How this request is retried when it fails.
    /// - Returns: A copy of the request with the retry policy.
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
    ///
    /// - Parameter policy: How this request reads from and writes to the cache.
    /// - Returns: A copy of the request with the cache policy.
    @discardableResult
    public func cachePolicy(_ policy: CachePolicy) -> Self {
        var copy = self
        copy.cachePolicy = policy
        return copy
    }

    /// Adds a middleware for this request only. It runs inside the client's middleware of the
    /// same scope, once per call or for every attempt. See ``MiddlewareScope``.
    ///
    /// - Parameters:
    ///   - middleware: The middleware to add. It runs after the ones added before it.
    ///   - scope: Whether it runs once per call or for every attempt
    ///     (default: ``MiddlewareScope/attempt``).
    /// - Returns: A copy of the request with the middleware added.
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
    ///
    /// - Parameters:
    ///   - scope: Whether it runs once per call or for every attempt
    ///     (default: ``MiddlewareScope/attempt``).
    ///   - intercept: Called with the request, its context, and `next`, which sends the request
    ///     on. Return the response from `next`, or one of your own.
    /// - Returns: A copy of the request with the middleware added.
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
    /// Attaches `fields` as a URL-encoded form body, such as `name=Ada+Lovelace&role=admin`, and
    /// sets `Content-Type` to `application/x-www-form-urlencoded`.
    ///
    /// Fields are sorted by name, so the same fields always produce the same body.
    ///
    /// - Parameter fields: The form fields, by name. Names and values are percent-encoded for
    ///   you.
    /// - Returns: A copy of the request with the form as its body.
    /// - Throws: Nothing at present. The method is declared `throws` to match ``json(_:)``.
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
            callTimeout: copy.callTimeout,
            attemptTimeout: copy.attemptTimeout,
            retryPolicy: copy.retryPolicy,
            attemptMiddlewares: copy.attemptMiddlewares,
            callMiddlewares: copy.callMiddlewares,
            cachePolicy: copy.cachePolicy,
            percentEncoder: copy.percentEncoder,
        )
    }

    /// Attaches `bodyObject` encoded as JSON, and sets `Content-Type` to `application/json`.
    ///
    /// It's encoded with a default `JSONEncoder`, so dates, keys and other values use its
    /// default strategies.
    ///
    /// - Throws: ``NetSkeinError/Kind/invalidPayload`` when `bodyObject` can't be encoded.
    /// - Parameter bodyObject: The value to send, such as a `Codable` struct.
    /// - Returns: A copy of the request with the JSON as its body.
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
                callTimeout: copy.callTimeout,
                attemptTimeout: copy.attemptTimeout,
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

    /// Attaches `form` as a `multipart/form-data` body, and sets `Content-Type` with the form's
    /// boundary.
    ///
    /// ```swift
    /// let form = MultipartForm.builder()
    ///     .text(name: "title", value: "Holiday")
    ///     .file(name: "photo", filename: "beach.jpg", contentType: "image/jpeg", body: photo)
    ///     .build()
    ///
    /// try await client.post("https://api.example.com/photos")
    ///     .multipart(form)
    ///     .send()
    /// ```
    ///
    /// The whole form is held in memory. To upload one large file, use
    /// ``file(atPath:chunkSize:onProgress:)`` instead.
    ///
    /// - Parameter form: The form to send. See ``MultipartForm``.
    /// - Returns: A copy of the request with the form as its body.
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
            callTimeout: copy.callTimeout,
            attemptTimeout: copy.attemptTimeout,
            retryPolicy: copy.retryPolicy,
            attemptMiddlewares: copy.attemptMiddlewares,
            callMiddlewares: copy.callMiddlewares,
            cachePolicy: copy.cachePolicy,
            percentEncoder: copy.percentEncoder,
        )
    }

    /// Attaches the file at `path` as the body, read in chunks while it's sent instead of loaded
    /// into memory, and sets `Content-Type` to `application/octet-stream`.
    ///
    /// Set ``header(_:_:)`` afterwards to send a more specific `Content-Type`.
    ///
    /// - Parameters:
    ///   - path: The path of a regular file. Symbolic links are followed.
    ///   - chunkSize: How many bytes are read from the file at a time (default: 64 KiB).
    ///   - onProgress: Called as chunks are sent, with the bytes sent so far and the file's size
    ///     (default: `nil`, for no progress reports).
    /// - Returns: A copy of the request with the file as its body.
    /// - Throws: ``NetSkeinError/Kind/ioFailure`` when `path` isn't a regular file or can't be
    ///   read. The check happens here, before the request is sent.
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
            callTimeout: copy.callTimeout,
            attemptTimeout: copy.attemptTimeout,
            retryPolicy: copy.retryPolicy,
            attemptMiddlewares: copy.attemptMiddlewares,
            callMiddlewares: copy.callMiddlewares,
            cachePolicy: copy.cachePolicy,
            percentEncoder: copy.percentEncoder,
        )
    }
}

extension NetSkeinRequest where Body == BodyForbidden {
    /// Lets a `GET` or `DELETE` request have a body.
    ///
    /// HTTP gives these bodies no meaning, and many servers, proxies and caches drop or reject
    /// them. Use it only for an API that requires one, such as a search endpoint that takes its
    /// query as a `GET` body.
    ///
    /// - Returns: A copy of the request that can take a body.
    @discardableResult
    public func dangerouslyAllowBody() -> NetSkeinRequest<BodyAllowed> {
        NetSkeinRequest<BodyAllowed>(
            client: self.client,
            method: self.method,
            url: self.url,
            headers: self.headers,
            body: self.body,
            maxResponseBytes: self.maxResponseBytes,
            callTimeout: self.callTimeout,
            attemptTimeout: self.attemptTimeout,
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
            callTimeout: callTimeout,
            attemptTimeout: attemptTimeout,
            retryPolicy: retryPolicy ?? client.retryPolicy,
            maxResponseBytes: responseLimit,
            callMiddlewares: client.callMiddlewares + callMiddlewares,
            attemptMiddlewares: attemptStack,
        )
    }
}

extension NetSkeinRequest {
    /// Sends the request and collects the whole response body in memory.
    ///
    /// Any status counts as a response, so a `404` or `500` returns normally. Call
    /// ``NetSkeinResponse/validate()`` to turn statuses outside `200..<300` into errors:
    ///
    /// ```swift
    /// let user = try await client.get(url)
    ///     .send()
    ///     .validate()
    ///     .json(User.self)
    /// ```
    ///
    /// Failed attempts are retried as the retry policy says, and the response may come from the
    /// client's ``HTTPCache``. The body is limited by ``maxResponseBytes(_:)``. To read a large
    /// body without holding it in memory, use ``stream()`` or
    /// ``download(toFileAtPath:resumption:onProgress:)``.
    ///
    /// - Returns: The response, with its body.
    /// - Throws: A ``NetSkeinError`` when no response arrives once the retry policy gives up, the
    ///   call runs out of time, or the body is larger than ``maxResponseBytes(_:)``.
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
    /// body has no size limit. See ``maxResponseBytes(_:)``.
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
    /// - Parameter maxLineLength: The longest line accepted, in bytes (default: 1 MiB). A longer
    ///   one makes the loop throw `invalidPayload`, so a server cannot make one endless line use
    ///   unbounded memory. `nil` removes the limit, so a line is held in memory however long it
    ///   gets.
    /// - Returns: The response, with its body still to be read.
    /// - Throws: ``NetSkeinError/badStatus(_:)`` for a response outside `200..<300`, or the
    ///   failure that remains once the retry policy gives up.
    public func lines(
        maxLineLength: Int? = 1024 * 1024
    ) async throws(NetSkeinError) -> NetSkeinLines {
        try await stream().lines(maxLineLength: maxLineLength)
    }

    /// Sends the request and writes the body of a successful response to the file at `path`,
    /// without holding it in memory.
    ///
    /// ```swift
    /// try await client.get("https://example.com/video.mp4")
    ///     .download(toFileAtPath: path, resumption: .onRetry) { written, total in
    ///         print("\(written) of \(total.map(String.init) ?? "?") bytes")
    ///     }
    /// ```
    ///
    /// The file is created, or replaced when it already exists, unless `resumption` is
    /// ``DownloadResumption/ifPossible(validator:)``. A download that fails leaves what it wrote
    /// on disk. Delete the file yourself if you don't want to resume it later.
    ///
    /// ## Retries and Resuming
    ///
    /// Unlike ``stream(_:)``, a download is retried even after part of the body was written,
    /// since each attempt either writes the file from the start or resumes it:
    ///
    /// - With ``DownloadResumption/disabled``, every attempt writes the file from the start.
    /// - Otherwise, an attempt that finds part of the file on disk asks for the rest with a
    ///   `Range` header, and `If-Range` when a strong validator is known. A `206 Partial Content`
    ///   response is appended to the file. A `200 OK` means the server sent the whole body,
    ///   which replaces the file.
    /// - A `416 Range Not Satisfiable` empties the file and throws
    ///   ``NetSkeinError/badStatus(_:)``, so the next download starts over.
    ///
    /// Only `GET` requests resume. Other methods always write the file from the start. Downloads
    /// are never cached.
    ///
    /// - Parameters:
    ///   - path: Where to write the body.
    ///   - resumption: Whether to resume a partial file (default: ``DownloadResumption/disabled``).
    ///   - onProgress: Called after each chunk is written, with the bytes in the file so far and
    ///     the expected total (default: `nil`). The total is `nil` when the server doesn't send
    ///     one. When resuming, both include the bytes already on disk.
    /// - Throws: ``NetSkeinError/badStatus(_:)`` for a response outside `200..<300`. A
    ///   ``NetSkeinError`` of kind ``NetSkeinError/Kind/ioFailure`` when the file can't be created
    ///   or written, or of kind ``NetSkeinError/Kind/networkFailure`` when the connection drops,
    ///   once the retry policy gives up.
    public func download(
        toFileAtPath path: String,
        resumption: DownloadResumption = .disabled,
        onProgress: DownloadProgress? = nil
    ) async throws(NetSkeinError) {
        try await executor(buffered: false)
            .download(to: path, resumption: resumption, onProgress: onProgress)
    }
}
