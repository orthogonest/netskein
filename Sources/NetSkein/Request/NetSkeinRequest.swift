import AsyncHTTPClient
import Logging
import NIOCore
import NIOHTTP1

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public struct NetSkeinRequest<Body: BodyState>: Sendable {
    private let client: NetSkeinClient
    private var method: HTTPMethod
    private var url: String
    private var headers: HTTPHeaders
    private var body: BodySource
    private var maxResponseBytes: Int
    private var timeout: TimeAmount?
    private var retryPolicy: RetryPolicy?
    private var middlewares: [any HTTPMiddleware]
    private let percentEncoder: PercentEncoder

    init(
        client: NetSkeinClient,
        method: HTTPMethod,
        url: String,
        headers: HTTPHeaders? = nil,
        body: BodySource = .none,
        maxResponseBytes: Int = 10 * 1024 * 1024,
        timeout: TimeAmount? = nil,
        retryPolicy: RetryPolicy? = nil,
        middlewares: [any HTTPMiddleware] = [],
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
        self.middlewares = middlewares
        self.percentEncoder = percentEncoder
    }
}

extension NetSkeinRequest where Body == BodyAllowed {
    public init(
        client: NetSkeinClient,
        method: HTTPMethod,
        url: String,
        headers: HTTPHeaders? = nil,
        maxResponseBytes: Int = 10 * 1024 * 1024,
        timeout: TimeAmount? = nil,
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

    @discardableResult
    public func query(_ items: [String: String]) -> Self {
        guard var components = URLComponents(string: url) else { return self }

        var queryItems = components.queryItems ?? []
        for (key, value) in items { queryItems.append(URLQueryItem(name: key, value: value)) }
        components.queryItems = queryItems

        var copy = self

        if let updatedURL = components.url?.absoluteString { copy.url = updatedURL }

        return copy
    }

    @discardableResult
    public func maxResponseBytes(_ bytes: Int) -> Self {
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

    /// Adds a middleware for this request only; it runs inside the client's middleware.
    @discardableResult
    public func using(_ middleware: some HTTPMiddleware) -> Self {
        var copy = self
        copy.middlewares.append(middleware)
        return copy
    }

    /// Adds a closure as a middleware for this request only.
    @discardableResult
    public func using(
        _ intercept:
            @escaping @Sendable (
                RequestHead,
                MiddlewareContext,
                HTTPMiddleware.Next
            ) async throws -> HTTPClientResponse
    ) -> Self {
        using(ClosureMiddleware(intercept))
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
            middlewares: copy.middlewares,
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
                middlewares: copy.middlewares,
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
            middlewares: copy.middlewares,
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
            middlewares: copy.middlewares,
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
            middlewares: self.middlewares,
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
    private var executor: RequestExecutor {
        RequestExecutor(
            client: client,
            method: method,
            url: url,
            headers: headers,
            body: body,
            timeout: timeout,
            retryPolicy: retryPolicy,
            maxResponseBytes: maxResponseBytes,
            middlewares: client.middlewares + middlewares,
        )
    }
}

extension NetSkeinRequest {
    public func send() async throws(NetSkeinError) -> NetSkeinResponse {
        try await executor.send()
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
        try await executor.stream(onChunk)
    }

    public func download(
        toFileAtPath path: String,
        resumption: DownloadResumption = .disabled,
        onProgress: DownloadProgress? = nil
    ) async throws(NetSkeinError) {
        try await executor.download(to: path, resumption: resumption, onProgress: onProgress)
    }
}
