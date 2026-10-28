import AsyncHTTPClient
import Logging
import NIOCore
import NIOHTTP1
import Tracing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct RequestExecutor: Sendable {
    let client: NetSkeinClient
    let method: HTTPMethod
    let url: String
    let headers: HTTPHeaders
    let body: BodySource
    let timeout: TimeAmount?
    let retryPolicy: RetryPolicy?
    let maxResponseBytes: Int
    let middlewares: [any HTTPMiddleware]
}

// MARK: - Request Preparation

extension RequestExecutor {
    private func prepareRequest(requestID: String, extraHeaders: HTTPHeaders) -> RequestHead {
        var activeHeaders = headers

        activeHeaders.replaceOrAdd(name: "X-Request-ID", value: requestID)

        if let cookieValue = getCookie() {
            activeHeaders.replaceOrAdd(name: "Cookie", value: cookieValue)
        }

        for (name, value) in extraHeaders {
            activeHeaders.replaceOrAdd(name: name, value: value)
        }

        return RequestHead(method: method, url: url, headers: activeHeaders)
    }

    private func getCookie() -> String? {
        guard
            let jar = client.cookieJar,
            let urlObject = URL(string: url),
            let host = urlObject.host,
            let cookieValue = jar.cookieHeader(for: host)
        else { return nil }
        return cookieValue
    }

    private func setCookie(cookieHeaders: [String]) {
        guard
            let jar = client.cookieJar,
            let urlObject = URL(string: url),
            let host = urlObject.host
        else { return }

        for cookie in cookieHeaders {
            let components = cookie.components(separatedBy: ";")
            guard let parts = components.first?.components(separatedBy: "="), parts.count == 2
            else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            jar.setCookie(host: host, name: name, value: value)
        }
    }
}

// MARK: - Attempt Execution

extension RequestExecutor {
    /// Starts an attempt and logs that it is being initiated or retried.
    private func beginAttempt(
        _ number: Int,
        requestID: String,
        description: String
    ) -> MiddlewareContext {
        var logger = client.logger
        logger[metadataKey: "request_id"] = .string(requestID)
        logger[metadataKey: "http_method"] = .string(method.rawValue)
        logger[metadataKey: "url"] = .string(url)
        if number > 0 {
            logger[metadataKey: "retry_attempt"] = .string("\(number)")
        }

        logger.info(number == 0 ? "Initiating \(description)" : "Retrying \(description)")

        return MiddlewareContext(
            attempt: number,
            requestID: requestID,
            logger: logger,
            body: body.bodyDescription
        )
    }

    private func execute(
        _ head: RequestHead,
        _ context: MiddlewareContext,
        action: String
    ) async throws -> HTTPClientResponse {
        try await MiddlewareChain.run(
            head,
            through: middlewares,
            context: context
        ) { head in
            var request = HTTPClientRequest(url: head.url)
            request.method = head.method
            request.headers = head.headers
            request.body = try body.makeBody()

            do {
                return try await client.transport.execute(
                    request,
                    timeout: timeout ?? .seconds(30),
                    logger: context.logger
                )
            } catch {
                throw mapError(error, context, action: action)
            }
        }
    }

    private func recordResponse(
        _ response: HTTPClientResponse,
        _ context: MiddlewareContext,
        startedAt startTime: DispatchTime
    ) {
        let endTime = DispatchTime.now()
        let duration =
            Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / Nanoseconds.toSeconds
        let activeResponseID = response.headers["X-Request-ID"].first ?? context.requestID

        context.logger.info(
            "Response received",
            metadata: [
                "request_id": .string(activeResponseID),
                "status_code": .string("\(response.status.code)"),
                "duration_seconds": .string(String(format: "%.4f", duration)),
            ]
        )

        let cookieHeaders = response.headers["Set-Cookie"]
        setCookie(cookieHeaders: cookieHeaders)
    }

    private func mapError(
        _ error: any Error,
        _ context: MiddlewareContext,
        action: String
    ) -> NetSkeinError {
        if let netSkeinError = error as? NetSkeinError {
            return netSkeinError
        }
        context.logger.error(
            "\(action) failed",
            metadata: [
                "request_id": .string(context.requestID),
                "error_description": .string(error.localizedDescription),
            ]
        )
        return .custom(
            kind: .networkFailure,
            message: "\(action) execution failed: \(error.localizedDescription)",
            underlyingError: error
        )
    }
}

// MARK: - Retry Loop

extension RequestExecutor {
    private var activeRetryPolicy: RetryPolicy {
        retryPolicy ?? client.retryPolicy
    }

    /// Sends the request until `operation` succeeds or the retry policy stops, all inside one
    /// span.
    ///
    /// Each attempt runs in this order: `operation.prepareAttempt()`, then the request is sent
    /// through the middleware and transport, then `operation.handle` turns the response into
    /// the result, then the retry policy decides whether to go again. Anything thrown along the
    /// way counts as a failed attempt.
    private func run<Operation: RequestOperation>(
        _ operation: Operation
    ) async throws(NetSkeinError) -> Operation.Output {
        var operation = operation
        let requestID = UUID().uuidString

        return try await traced(operation.name) { span throws(NetSkeinError) in
            span?.attributes["netskein.request_id"] = requestID
            return try await makeAttempt(0, of: &operation, requestID: requestID, span: span)
        }
    }

    /// Makes attempt `number`, then either finishes the call or backs off and makes the next one.
    private func makeAttempt<Operation: RequestOperation>(
        _ number: Int,
        of operation: inout Operation,
        requestID: String,
        span: (any Span)?
    ) async throws(NetSkeinError) -> Operation.Output {
        try checkCancellation()

        let setup = operation.prepareAttempt()
        let head = prepareRequest(requestID: requestID, extraHeaders: setup.extraHeaders)
        let context = beginAttempt(number, requestID: requestID, description: setup.description)
        if number > 0 {
            span?.attributes["http.request.resend_count"] = number
        }

        let startTime = DispatchTime.now()
        var response: HTTPClientResponse?
        do {
            let received = try await execute(head, context, action: operation.action)
            response = received
            span?.attributes["http.response.status_code"] = Int(received.status.code)
            recordResponse(received, context, startedAt: startTime)

            let result = try await operation.handle(received, logger: context.logger)
            guard
                operation.isBuffered,
                await shouldRetry(
                    after: context,
                    status: received.status,
                    headers: received.headers,
                    error: nil
                )
            else { return result }
        } catch {
            let failure = mapError(error, context, action: operation.action)
            guard
                !operation.hasDeliveredData,
                await shouldRetry(
                    after: context,
                    status: response?.status,
                    headers: response?.headers,
                    error: failure
                )
            else { throw failure }
        }

        try await backOff(before: number + 1, responseHeaders: response?.headers)
        return try await makeAttempt(number + 1, of: &operation, requestID: requestID, span: span)
    }

    /// Asks the retry policy whether the attempt described by `context` should be followed by
    /// another one.
    private func shouldRetry(
        after context: MiddlewareContext,
        status: HTTPResponseStatus?,
        headers: HTTPHeaders?,
        error: NetSkeinError?
    ) async -> Bool {
        let policy = activeRetryPolicy
        let nextNumber = context.attempt + 1

        let retryContext = RetryContext(
            attempt: nextNumber,
            maxRetries: policy.maxRetries,
            method: method,
            url: url,
            responseStatus: status,
            responseHeaders: headers,
            error: error
        )

        guard await policy.evaluator(retryContext), nextNumber <= policy.maxRetries else {
            return false
        }

        context.logger.warning(
            "Request eligible for retry. Backing off before attempt \(nextNumber + 1)",
            metadata: [
                "attempt": .string("\(nextNumber)"),
                "max_retries": .string("\(policy.maxRetries)"),
            ]
        )

        return true
    }

    /// Waits before attempt `number`, as long as the policy's backoff or a `Retry-After`
    /// header asks, whichever is longer.
    private func backOff(
        before number: Int,
        responseHeaders: HTTPHeaders?
    ) async throws(NetSkeinError) {
        let policy = activeRetryPolicy
        var delay = policy.backoff.delay(forAttempt: number)

        if policy.respectRetryAfterHeader,
            let retryAfterDelay = RetryAfterParser.parseDelay(from: responseHeaders),
            retryAfterDelay.nanoseconds > delay.nanoseconds
        {
            delay = retryAfterDelay
        }

        do {
            try Task.checkCancellation()
            let nanoseconds = UInt64(max(0, delay.nanoseconds))
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            throw .custom(
                kind: .networkFailure,
                message: "Retry sleep cancelled or interrupted: \(error.localizedDescription)",
                underlyingError: error
            )
        }
    }
}

// MARK: - Tracing

extension RequestExecutor {
    /// Runs one call, including all of its retry attempts, inside a span, so the transport's
    /// per-attempt spans are grouped under it and the span covers backoff and body transfer.
    private func traced<Success>(
        _ operation: String,
        _ body: ((any Span)?) async throws(NetSkeinError) -> Success
    ) async throws(NetSkeinError) -> Success {
        guard let tracer = client.tracer else { return try await body(nil) }

        let span = tracer.startSpan("NetSkein \(method.rawValue)", ofKind: .internal)
        defer { span.end() }
        span.attributes["http.request.method"] = method.rawValue
        span.attributes["netskein.operation"] = operation

        // Make the span current, so the transport's spans become its children
        let result = await ServiceContext.$current.withValue(span.context) {
            await Result { () async throws(NetSkeinError) in try await body(span) }
        }
        if case let .failure(error) = result {
            span.recordError(error)
            span.setStatus(SpanStatus(code: .error))
        }
        return try result.get()
    }
}

// MARK: - Entry Points

extension RequestExecutor {
    func send() async throws(NetSkeinError) -> NetSkeinResponse {
        try await run(SendOperation(maxResponseBytes: maxResponseBytes))
    }

    func stream(
        _ onChunk: @escaping ChunkHandler
    ) async throws(NetSkeinError) -> (status: HTTPResponseStatus, headers: HTTPHeaders) {
        try await run(StreamOperation(onChunk: onChunk))
    }

    func download(
        to path: String,
        resumption: DownloadResumption = .disabled,
        onProgress: DownloadProgress? = nil
    ) async throws(NetSkeinError) {
        let operation = DownloadOperation(
            path: path,
            resumption: resumption,
            canResume: method == .GET,
            onProgress: onProgress
        )
        operation.discardStaleFile()
        try await run(operation)
    }
}

// MARK: - Operations

/// What one kind of call does with each attempt's response. ``RequestExecutor`` does everything
/// else: building the request, middleware, transport, retries, backoff and tracing.
private protocol RequestOperation {
    associatedtype Output

    /// Names the call in spans, for example `send`.
    var name: String { get }

    /// Names the call in error logs and error messages, for example `Network request`.
    var action: String { get }

    /// Whether the whole response is collected before the caller sees any of it.
    ///
    /// Only a buffered call can retry after its response was handled: nothing has reached
    /// the caller yet, so the response can simply be thrown away.
    var isBuffered: Bool { get }

    /// Whether the caller has already received part of a response.
    ///
    /// A failure after that is never retried: the next attempt would start the response from
    /// the beginning and hand the caller the same data twice.
    var hasDeliveredData: Bool { get }

    /// Runs before every attempt: describes it in logs and adds any headers it needs.
    mutating func prepareAttempt() -> AttemptSetup

    /// Turns an attempt's response into the call's result. Throwing counts as a failed attempt.
    mutating func handle(_ response: HTTPClientResponse, logger: Logger) async throws -> Output
}

/// How one attempt is described in logs, and any headers it adds to the request.
private struct AttemptSetup {
    var description: String
    var extraHeaders: HTTPHeaders = [:]
}

/// Collects the whole response body in memory.
private struct SendOperation: RequestOperation {
    let maxResponseBytes: Int

    var name: String { "send" }
    var action: String { "Network request" }
    var isBuffered: Bool { true }
    var hasDeliveredData: Bool { false }

    func prepareAttempt() -> AttemptSetup {
        AttemptSetup(description: "outbound network request")
    }

    func handle(_ response: HTTPClientResponse, logger: Logger) async throws -> NetSkeinResponse {
        try await NetSkeinResponse(underlyingResponse: response, maxBytes: maxResponseBytes)
    }
}

/// Hands each chunk of a successful response to the caller as it arrives.
private struct StreamOperation: RequestOperation {
    let onChunk: ChunkHandler

    var name: String { "stream" }
    var action: String { "Streaming request" }
    var isBuffered: Bool { false }
    private(set) var hasDeliveredData = false

    func prepareAttempt() -> AttemptSetup {
        AttemptSetup(description: "outbound streaming request")
    }

    mutating func handle(
        _ response: HTTPClientResponse,
        logger: Logger
    ) async throws -> (status: HTTPResponseStatus, headers: HTTPHeaders) {
        guard response.status.code >= 200 && response.status.code < 300 else {
            throw NetSkeinError.badStatus(response.status)
        }

        let expectedBytes = response.headers.first(name: "Content-Length")
            .flatMap(Int64.init)
        var receivedBytes: Int64 = 0

        for try await buffer in response.body {
            try checkCancellation()
            receivedBytes += Int64(buffer.readableBytes)
            hasDeliveredData = true
            do {
                try await onChunk(buffer, receivedBytes, expectedBytes)
            } catch {
                throw NetSkeinError.custom(
                    kind: .clientError,
                    message:
                        "Streaming chunk consumer callback failed: \(error.localizedDescription)",
                    underlyingError: error
                )
            }
        }

        logger.info(
            "Finished streaming response body. Total bytes received: \(receivedBytes)"
        )

        return (response.status, response.headers)
    }
}

/// Writes a successful response to a file, resuming a partial file with `Range` requests
/// when the caller allows it.
private struct DownloadOperation: RequestOperation {
    let path: String
    let resumption: DownloadResumption
    /// Only `GET` requests can be resumed with `Range`.
    let canResume: Bool
    let onProgress: DownloadProgress?

    var name: String { "download" }
    var action: String { "Streaming download" }
    var isBuffered: Bool { false }
    /// A retry rewrites the file or resumes it where it stopped, so nothing is duplicated.
    var hasDeliveredData: Bool { false }

    /// How much of the file already exists before the current attempt.
    private var existingBytes: Int64 = 0
    /// The server's `ETag` or `Last-Modified`, sent as `If-Range` when resuming.
    private var validator: String?

    init(
        path: String,
        resumption: DownloadResumption,
        canResume: Bool,
        onProgress: DownloadProgress?
    ) {
        self.path = path
        self.resumption = resumption
        self.canResume = canResume
        self.onProgress = onProgress
        self.validator = resumption.validator
    }
}

extension DownloadOperation {
    /// Empties a file left by an earlier download unless the caller asked to resume it.
    func discardStaleFile() {
        guard
            resumption == .disabled || resumption == .onRetry,
            FileManager.default.fileExists(atPath: path)
        else { return }
        FileManager.default.createFile(atPath: path, contents: nil)
    }

    /// Measures what is already on disk and, when possible, asks only for the missing bytes.
    mutating func prepareAttempt() -> AttemptSetup {
        existingBytes = resumableFileSize()

        guard existingBytes > 0 && canResume else {
            return AttemptSetup(description: "file download")
        }

        var headers: HTTPHeaders = ["Range": "bytes=\(existingBytes)-"]
        if let validator {
            headers.add(name: "If-Range", value: validator)
        }

        return AttemptSetup(
            description: "download resumption from byte \(existingBytes)",
            extraHeaders: headers
        )
    }

    /// Remembers the server's validator and rejects responses that cannot be written.
    private mutating func accept(
        _ response: HTTPClientResponse,
        logger: Logger
    ) throws(NetSkeinError) {
        if let etag = response.headers.first(name: "ETag") {
            validator = etag
        } else if let lastModified = response.headers.first(name: "Last-Modified") {
            validator = lastModified
        }

        // 416 Range Not Satisfiable: start the file over so the retry downloads it in full
        if response.status == .rangeNotSatisfiable {
            logger.warning("416 Range Not Satisfiable received. Truncating file to byte 0.")
            FileManager.default.createFile(atPath: path, contents: nil)
            validator = nil
            throw .badStatus(response.status)
        }

        guard response.status.code >= 200 && response.status.code < 300 else {
            throw .badStatus(response.status)
        }
    }

    private func resumableFileSize() -> Int64 {
        guard
            resumption != .disabled,
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attributes[.size] as? Int64
        else { return 0 }
        return size
    }

    /// Remembers the server's validator, rejects responses that cannot be written, and writes
    /// the rest.
    mutating func handle(_ response: HTTPClientResponse, logger: Logger) async throws {
        try accept(response, logger: logger)
        try await writeBody(of: response, logger: logger)
    }

    /// Writes the body to the file: appending after a `206 Partial Content`, otherwise
    /// starting the file over.
    private func writeBody(
        of response: HTTPClientResponse,
        logger: Logger
    ) async throws(NetSkeinError) {
        let fileHandle: FileHandle
        var receivedBytes: Int64
        let totalExpectedBytes: Int64?

        do {
            // Server accepted Range -> Append to existing bytes
            if response.status == .partialContent {
                guard let handle = FileHandle(forWritingAtPath: path) else {
                    throw NetSkeinError.custom(
                        kind: .ioFailure,
                        message: "Cannot open file handle for append: \(path)"
                    )
                }

                try handle.seekToEnd()
                fileHandle = handle
                receivedBytes = existingBytes

                let contentRange = response.headers.first(name: "Content-Range")
                let parsedTotal = ContentRangeParser.parseTotalBytes(from: contentRange)
                let contentLength = response.headers.first(name: "Content-Length")
                    .flatMap(Int64.init)
                totalExpectedBytes = parsedTotal ?? contentLength.map { $0 + existingBytes }
            }
            // Server returned 200 OK -> Truncate/create fresh from byte 0
            else {
                guard
                    FileManager.default.createFile(atPath: path, contents: nil),
                    let handle = FileHandle(forWritingAtPath: path)
                else {
                    throw NetSkeinError.custom(
                        kind: .ioFailure,
                        message: "Cannot create file at: \(path)"
                    )
                }
                fileHandle = handle
                receivedBytes = 0
                totalExpectedBytes = response.headers.first(name: "Content-Length")
                    .flatMap(Int64.init)
            }
        } catch let error as NetSkeinError {
            throw error
        } catch {
            throw NetSkeinError.custom(
                kind: .ioFailure,
                message:
                    "Filesystem error while preparing download target: \(error.localizedDescription)",
                underlyingError: error
            )
        }

        defer {
            try? fileHandle.close()
        }

        // Stream the body chunks directly to disk
        do {
            for try await buffer in response.body {
                try checkCancellation()
                let chunkSize = Int64(buffer.readableBytes)

                do {
                    try buffer.withUnsafeReadableBytes { bytes in
                        guard let baseAddress = bytes.baseAddress, !bytes.isEmpty else { return }
                        let data = Data(
                            bytesNoCopy: UnsafeMutableRawPointer(mutating: baseAddress),
                            count: bytes.count,
                            deallocator: .none
                        )
                        try fileHandle.write(contentsOf: data)
                    }
                } catch {
                    throw NetSkeinError.custom(
                        kind: .ioFailure,
                        message:
                            "Failed writing chunk to disk at \(path): \(error.localizedDescription)",
                        underlyingError: error
                    )
                }

                receivedBytes += chunkSize
                onProgress?(receivedBytes, totalExpectedBytes)
            }

            logger.info(
                "File download finished successfully. Total bytes: \(receivedBytes)"
            )
        } catch let error as NetSkeinError {
            throw error
        } catch {
            throw NetSkeinError.custom(
                kind: .networkFailure,
                message:
                    "Network connection dropped during file download: \(error.localizedDescription)",
                underlyingError: error
            )
        }
    }
}

// MARK: - Cancellation

private func checkCancellation() throws(NetSkeinError) {
    if Task.isCancelled {
        throw .custom(
            kind: .networkFailure,
            message: "Task was cancelled before the request could complete.",
            underlyingError: CancellationError()
        )
    }
}
