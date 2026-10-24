import AsyncHTTPClient
import Logging
import NIOCore
import NIOHTTP1

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public struct NetSkeinRequest<Transport: HTTPTransport, Body: BodyState>: Sendable {
    private let client: NetSkeinClient<Transport>
    private var method: HTTPMethod
    private var url: String
    private var headers: HTTPHeaders
    private var body: BodySource
    private var maxResponseBytes: Int
    private var timeout: TimeAmount?
    private var retryPolicy: RetryPolicy?
    private let percentEncoder: PercentEncoder

    init(
        client: NetSkeinClient<Transport>,
        method: HTTPMethod,
        url: String,
        headers: HTTPHeaders? = nil,
        body: BodySource = .none,
        maxResponseBytes: Int = 10 * 1024 * 1024,
        timeout: TimeAmount? = nil,
        retryPolicy: RetryPolicy? = nil,
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
        self.percentEncoder = percentEncoder
    }
}

extension NetSkeinRequest where Body == BodyAllowed {
    public init(
        client: NetSkeinClient<Transport>,
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
}

extension NetSkeinRequest where Body == BodyAllowed {
    @discardableResult
    public func form(
        _ fields: [String: String]
    ) throws(NetSkeinError) -> NetSkeinRequest<Transport, BodyAttached> {
        let queryString = percentEncoder.encodeForm(fields)
        let data = Data(queryString.utf8)
        let allocator = ByteBufferAllocator()
        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)

        var copy = self
        copy.body = .bytes(buffer)
        copy.headers.replaceOrAdd(name: "Content-Type", value: "application/x-www-form-urlencoded")

        return NetSkeinRequest<Transport, BodyAttached>(
            client: copy.client,
            method: copy.method,
            url: copy.url,
            headers: copy.headers,
            body: copy.body,
            maxResponseBytes: copy.maxResponseBytes,
            timeout: copy.timeout,
            retryPolicy: copy.retryPolicy,
            percentEncoder: copy.percentEncoder,
        )
    }

    @discardableResult
    public func json(
        _ bodyObject: some Encodable
    ) throws(NetSkeinError) -> NetSkeinRequest<Transport, BodyAttached> {
        do {
            let data = try JSONEncoder().encode(bodyObject)
            let allocator = ByteBufferAllocator()
            var buffer = allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)

            var copy = self
            copy.body = .bytes(buffer)
            copy.headers.replaceOrAdd(name: "Content-Type", value: "application/json")

            return NetSkeinRequest<Transport, BodyAttached>(
                client: copy.client,
                method: copy.method,
                url: copy.url,
                headers: copy.headers,
                body: copy.body,
                maxResponseBytes: copy.maxResponseBytes,
                timeout: copy.timeout,
                retryPolicy: copy.retryPolicy,
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
    ) -> NetSkeinRequest<Transport, BodyAttached> {
        var copy = self
        copy.body = .bytes(form.bytes())
        copy.headers.replaceOrAdd(
            name: "Content-Type",
            value: "multipart/form-data; boundary=\(form.boundary)"
        )

        return NetSkeinRequest<Transport, BodyAttached>(
            client: copy.client,
            method: copy.method,
            url: copy.url,
            headers: copy.headers,
            body: copy.body,
            maxResponseBytes: copy.maxResponseBytes,
            timeout: copy.timeout,
            retryPolicy: copy.retryPolicy,
            percentEncoder: copy.percentEncoder,
        )
    }

    @discardableResult
    public func file(
        atPath path: String,
        chunkSize: Int = 64 * 1024,
        onProgress: UploadProgress? = nil
    ) throws(NetSkeinError) -> NetSkeinRequest<Transport, BodyAttached> {
        guard
            let fileAttributes = try? FileManager.default.attributesOfItem(atPath: path),
            let fileSize = fileAttributes[.size] as? Int64
        else {
            throw .custom(
                kind: .ioFailure,
                message: "Failed to retrieve file attributes or file size at path: \(path)",
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
            fileSize: fileSize,
            onProgress: onProgress
        )
        copy.headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
        copy.headers.replaceOrAdd(name: "Content-Type", value: "application/octet-stream")

        return NetSkeinRequest<Transport, BodyAttached>(
            client: copy.client,
            method: copy.method,
            url: copy.url,
            headers: copy.headers,
            body: copy.body,
            maxResponseBytes: copy.maxResponseBytes,
            timeout: copy.timeout,
            retryPolicy: copy.retryPolicy,
            percentEncoder: copy.percentEncoder,
        )
    }
}

extension NetSkeinRequest where Body == BodyForbidden {
    @discardableResult
    public func dangerouslyAllowBody() -> NetSkeinRequest<Transport, BodyAllowed> {
        NetSkeinRequest<Transport, BodyAllowed>(
            client: self.client,
            method: self.method,
            url: self.url,
            headers: self.headers,
            body: self.body,
            maxResponseBytes: self.maxResponseBytes,
            timeout: self.timeout,
            retryPolicy: self.retryPolicy,
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
    ) throws(NetSkeinError) -> NetSkeinRequest<Transport, BodyAttached> {
        fatalError("Unavailable at compile time")
    }

    @available(
        *,
        unavailable,
        message: "This HTTP method is forbidden from holding a request body payload."
    )
    public func json(
        _ bodyObject: some Encodable
    ) throws(NetSkeinError) -> NetSkeinRequest<Transport, BodyAttached> {
        fatalError("Unavailable at compile time")
    }

    @available(
        *,
        unavailable,
        message: "This HTTP method is forbidden from holding a request body payload."
    )
    public func multipart(
        _ form: MultipartForm
    ) -> NetSkeinRequest<Transport, BodyAttached> {
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
    ) throws(NetSkeinError) -> NetSkeinRequest<Transport, BodyAttached> {
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
    ) throws(NetSkeinError) -> NetSkeinRequest<Transport, BodyAttached> {
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
    ) throws(NetSkeinError) -> NetSkeinRequest<Transport, BodyAttached> {
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
    ) -> NetSkeinRequest<Transport, BodyAttached> {
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

    ) throws(NetSkeinError) -> NetSkeinRequest<Transport, BodyAttached> {
        fatalError("Unavailable at compile time")
    }
}

extension NetSkeinRequest {
    private var executor: RequestExecutor<Transport> {
        RequestExecutor(
            client: client,
            method: method,
            url: url,
            headers: headers,
            body: body,
            timeout: timeout,
            retryPolicy: retryPolicy,
            maxResponseBytes: maxResponseBytes,
        )
    }
}

extension NetSkeinRequest {
    public func send() async throws(NetSkeinError) -> NetSkeinResponse {
        try await executor.execute()
    }

    @discardableResult
    public func stream(
        _ onChunk: ChunkHandler
    ) async throws(NetSkeinError) -> (status: HTTPResponseStatus, headers: HTTPHeaders) {
        try await executor.execute(stream: onChunk)
    }

    public func download(
        toFileAtPath path: String,
        resumption: DownloadResumption = .disabled,
        onProgress: DownloadProgress? = nil
    ) async throws(NetSkeinError) {
        try await executor.execute(downloadTo: path, resumption: resumption, onProgress: onProgress)
    }
}
