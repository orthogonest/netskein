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

struct RequestExecutor<Transport: HTTPTransport>: Sendable {
    let client: NetSkeinClient<Transport>
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
    private func checkCancellation() throws(NetSkeinError) {
        if Task.isCancelled {
            throw .custom(
                kind: .networkFailure,
                message: "Task was cancelled before the request could complete.",
                underlyingError: CancellationError()
            )
        }
    }

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

    private func prepareLogger(
        requestID: String,
        attempt: Int,
        action: String
    ) -> Logger {
        var logger = client.logger
        logger[metadataKey: "request_id"] = .string(requestID)
        logger[metadataKey: "http_method"] = .string(method.rawValue)
        logger[metadataKey: "url"] = .string(url)
        if attempt > 0 {
            logger[metadataKey: "retry_attempt"] = .string("\(attempt)")
        }

        logger.info(attempt == 0 ? "Initiating \(action)" : "Retrying \(action)")
        return logger
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
    private func execute(
        _ head: RequestHead,
        requestID: String,
        attempt: Int,
        action: String,
        logger: Logger
    ) async throws -> HTTPClientResponse {
        let context = MiddlewareContext(
            attempt: attempt,
            requestID: requestID,
            logger: logger,
            body: body.bodyDescription
        )

        return try await MiddlewareChain.run(
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
                    logger: logger
                )
            } catch {
                throw mapError(error, requestID: requestID, action: action, logger: logger)
            }
        }
    }

    private func recordResponse(
        _ response: HTTPClientResponse,
        requestID: String,
        startTime: DispatchTime,
        logger: Logger,
    ) {
        let endTime = DispatchTime.now()
        let duration =
            Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / Nanoseconds.toSeconds
        let activeResponseID = response.headers["X-Request-ID"].first ?? requestID

        logger.info(
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
        requestID: String,
        action: String,
        logger: Logger
    ) -> NetSkeinError {
        if let netSkeinError = error as? NetSkeinError {
            return netSkeinError
        }
        logger.error(
            "\(action) failed",
            metadata: [
                "request_id": .string(requestID),
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
    /// The kinds of call the executor runs. They share one retry loop and differ only in how
    /// each attempt is set up and how its response is handled.
    private enum Operation: String {
        case send
        case stream
        case download

        /// Names the call in error logs and error messages.
        var action: String {
            switch self {
            case .send: "Network request"
            case .stream: "Streaming request"
            case .download: "Streaming download"
            }
        }

        /// Whether a response that was handled without throwing can still be retried.
        ///
        /// Only buffered calls can: streamed chunks and written bytes cannot be taken back, so
        /// those calls reject unwanted statuses by throwing instead.
        var retriesHandledResponses: Bool { self == .send }
    }

    /// How one attempt is described in logs, and any headers it adds to the request.
    private struct AttemptSetup {
        var description: String
        var extraHeaders: HTTPHeaders = [:]
    }

    private var activeRetryPolicy: RetryPolicy {
        retryPolicy ?? client.retryPolicy
    }

    /// Sends the request until it succeeds or the retry policy stops, all inside one span.
    ///
    /// Each attempt runs in this order: `prepareAttempt`, then the request is sent through the
    /// middleware and transport, then `handle` turns the response into the result, then the
    /// retry policy decides whether to go again. Anything thrown along the way counts as a
    /// failed attempt.
    private func retrying<Success>(
        _ operation: Operation,
        prepareAttempt: () -> AttemptSetup,
        handle: (HTTPClientResponse, Logger) async throws -> Success
    ) async throws(NetSkeinError) -> Success {
        try await traced(operation.rawValue) { span throws(NetSkeinError) in
            try await runAttempts(
                operation,
                span: span,
                prepareAttempt: prepareAttempt,
                handle: handle
            )
        }
    }

    private func runAttempts<Success>(
        _ operation: Operation,
        span: (any Span)?,
        prepareAttempt: () -> AttemptSetup,
        handle: (HTTPClientResponse, Logger) async throws -> Success
    ) async throws(NetSkeinError) -> Success {
        var attempt = 0
        var outcome: Result<Success, NetSkeinError>
        var shouldRetry: Bool
        let requestID = UUID().uuidString
        span?.attributes["netskein.request_id"] = requestID

        repeat {
            try checkCancellation()

            let setup = prepareAttempt()
            let head = prepareRequest(requestID: requestID, extraHeaders: setup.extraHeaders)
            let logger = prepareLogger(
                requestID: requestID,
                attempt: attempt,
                action: setup.description
            )
            if attempt > 0 {
                span?.attributes["http.request.resend_count"] = attempt
            }

            let startTime: DispatchTime = .now()
            var rawResponse: HTTPClientResponse?

            do {
                let response = try await execute(
                    head,
                    requestID: requestID,
                    attempt: attempt,
                    action: operation.action,
                    logger: logger
                )
                rawResponse = response
                span?.attributes["http.response.status_code"] = Int(response.status.code)
                recordResponse(response, requestID: requestID, startTime: startTime, logger: logger)

                outcome = .success(try await handle(response, logger))
                if operation.retriesHandledResponses {
                    shouldRetry = try await evaluateRetry(
                        policy: activeRetryPolicy,
                        attempt: &attempt,
                        status: response.status,
                        headers: response.headers,
                        error: nil,
                        logger: logger
                    )
                } else {
                    shouldRetry = false
                }
            } catch {
                let mappedError = mapError(
                    error,
                    requestID: requestID,
                    action: operation.action,
                    logger: logger
                )

                outcome = .failure(mappedError)
                shouldRetry = try await evaluateRetry(
                    policy: activeRetryPolicy,
                    attempt: &attempt,
                    status: rawResponse?.status,
                    headers: rawResponse?.headers,
                    error: mappedError,
                    logger: logger
                )
            }
        } while shouldRetry

        return try outcome.get()
    }

    private func evaluateRetry(
        policy: RetryPolicy,
        attempt: inout Int,
        status: HTTPResponseStatus?,
        headers: HTTPHeaders?,
        error: NetSkeinError?,
        logger: Logger
    ) async throws(NetSkeinError) -> Bool {
        attempt += 1

        let context = RetryContext(
            attempt: attempt,
            maxRetries: policy.maxRetries,
            method: method,
            url: url,
            responseStatus: status,
            responseHeaders: headers,
            error: error
        )

        let shouldRetry = await policy.evaluator(context)

        if shouldRetry && attempt <= policy.maxRetries {
            logger.warning(
                "Request eligible for retry. Backing off before attempt \(attempt + 1)",
                metadata: [
                    "attempt": .string("\(attempt)"),
                    "max_retries": .string("\(policy.maxRetries)"),
                ]
            )
            try await sleepBetweenRetries(
                policy: policy,
                attempt: attempt,
                responseHeaders: headers
            )
            return true
        }

        return false
    }

    private func sleepBetweenRetries(
        policy: RetryPolicy,
        attempt: Int,
        responseHeaders: HTTPHeaders?
    ) async throws(NetSkeinError) {
        var delay = policy.backoff.delay(forAttempt: attempt)

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

// MARK: - Buffered Execution

extension RequestExecutor {
    func send() async throws(NetSkeinError) -> NetSkeinResponse {
        try await retrying(
            .send,
            prepareAttempt: { AttemptSetup(description: "outbound network request") },
            handle: { response, _ in
                try await NetSkeinResponse(underlyingResponse: response, maxBytes: maxResponseBytes)
            }
        )
    }
}

// MARK: - Streaming Execution

extension RequestExecutor {
    func stream(
        _ onChunk: ChunkHandler
    ) async throws(NetSkeinError) -> (status: HTTPResponseStatus, headers: HTTPHeaders) {
        try await retrying(
            .stream,
            prepareAttempt: { AttemptSetup(description: "outbound streaming request") },
            handle: { response, logger in
                guard response.status.code >= 200 && response.status.code < 300 else {
                    throw NetSkeinError.badStatus(response.status)
                }

                let expectedBytes = response.headers.first(name: "Content-Length")
                    .flatMap(Int64.init)
                var receivedBytes: Int64 = 0

                for try await buffer in response.body {
                    try checkCancellation()
                    receivedBytes += Int64(buffer.readableBytes)
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
        )
    }
}

// MARK: - File Download Execution

extension RequestExecutor {
    func download(
        to path: String,
        resumption: DownloadResumption = .disabled,
        onProgress: DownloadProgress? = nil
    ) async throws(NetSkeinError) {
        var target = DownloadTarget(path: path, resumption: resumption, canResume: method == .GET)
        target.discardStaleFile()

        try await retrying(
            .download,
            prepareAttempt: { target.nextAttempt() },
            handle: { response, logger in
                try target.accept(response, logger: logger)
                try await writeResponseBodyToFile(
                    response: response,
                    path: path,
                    existingBytes: target.existingBytes,
                    logger: logger,
                    onProgress: onProgress
                )
            }
        )
    }

    /// The download's file between attempts: how much of it exists, and the server validator
    /// that lets a later attempt resume it with a `Range` request.
    private struct DownloadTarget {
        let path: String
        let resumption: DownloadResumption
        /// Only `GET` requests can be resumed with `Range`.
        let canResume: Bool
        private(set) var existingBytes: Int64 = 0
        private var validator: String?

        init(path: String, resumption: DownloadResumption, canResume: Bool) {
            self.path = path
            self.resumption = resumption
            self.canResume = canResume
            self.validator = resumption.validator
        }

        /// Empties a file left by an earlier download unless the caller asked to resume it.
        func discardStaleFile() {
            guard
                resumption == .disabled || resumption == .onRetry,
                FileManager.default.fileExists(atPath: path)
            else { return }
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        /// Measures what is already on disk and, when possible, asks only for the missing bytes.
        mutating func nextAttempt() -> AttemptSetup {
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
        mutating func accept(_ response: HTTPClientResponse, logger: Logger) throws(NetSkeinError) {
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
    }

    private func writeResponseBodyToFile(
        response: HTTPClientResponse,
        path: String,
        existingBytes: Int64,
        logger: Logger,
        onProgress: DownloadProgress? = nil
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
