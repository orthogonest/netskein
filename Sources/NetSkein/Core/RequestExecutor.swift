import AsyncHTTPClient
import Logging
import NIOCore
import NIOHTTP1

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct RequestExecutor<Client: HTTPClientProtocol>: Sendable {
    let client: NetSkeinClient<Client>
    let method: HTTPMethod
    let url: String
    let headers: HTTPHeaders
    let body: BodySource
    let timeout: TimeAmount?
    let retryPolicy: RetryPolicy?
    let maxResponseBytes: Int
}

extension RequestExecutor {
    private var activeRetryPolicy: RetryPolicy {
        retryPolicy ?? client.retryPolicy
    }

    private func checkCancellation() throws(NetSkeinError) {
        if Task.isCancelled {
            throw .custom(
                kind: .networkFailure,
                message: "Task was cancelled before the request could complete.",
                underlyingError: CancellationError()
            )
        }
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

    private func prepareRequest(
        attempt: Int,
        headerModifier: ((inout HTTPHeaders) -> Void)? = nil
    ) throws(NetSkeinError) -> (request: HTTPClientRequest, requestID: String) {
        var activeHeaders = headers

        let requestID = UUID().uuidString
        activeHeaders.replaceOrAdd(name: "X-Request-ID", value: requestID)

        if let cookieValue = getCookie() {
            activeHeaders.replaceOrAdd(name: "Cookie", value: cookieValue)
        }

        headerModifier?(&activeHeaders)

        var request = HTTPClientRequest(url: url)
        request.method = method
        request.headers = activeHeaders
        request.body = try body.makeBody()

        return (request, requestID)
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

    private func recordResponse(
        _ response: HTTPClientResponse,
        requestID: String,
        startTime: DispatchTime,
        logger: Logger,
    ) {
        let endTime = DispatchTime.now()
        let duration =
            Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / NanoSeconds.toSeconds
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
            if response.status == .partialContent {
                // Server accepted Range -> Append to existing bytes
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
            } else {
                // Server returned 200 OK -> Truncate/create fresh from byte 0
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

// MARK: Buffered Execution

extension RequestExecutor {
    func execute() async throws(NetSkeinError) -> NetSkeinResponse {
        var attempt = 0

        while true {
            try checkCancellation()

            let (request, requestID) = try prepareRequest(attempt: attempt)
            let logger = prepareLogger(
                requestID: requestID,
                attempt: attempt,
                action: "outbound network request"
            )

            let startTime: DispatchTime = .now()
            var rawResponse: HTTPClientResponse?

            do {
                let response = try await client.underlyingClient.execute(
                    request,
                    timeout: timeout ?? .seconds(30),
                    logger: logger
                )
                rawResponse = response
                recordResponse(response, requestID: requestID, startTime: startTime, logger: logger)

                let netSkeinResponse = try await NetSkeinResponse(
                    underlyingResponse: response,
                    maxBytes: maxResponseBytes
                )

                if try await evaluateRetry(
                    policy: activeRetryPolicy,
                    attempt: &attempt,
                    status: netSkeinResponse.status,
                    headers: netSkeinResponse.headers,
                    error: nil,
                    logger: logger
                ) {
                    continue
                }

                return netSkeinResponse
            } catch {
                let mappedError = mapError(
                    error,
                    requestID: requestID,
                    action: "Network request",
                    logger: logger
                )

                if try await evaluateRetry(
                    policy: activeRetryPolicy,
                    attempt: &attempt,
                    status: rawResponse?.status,
                    headers: rawResponse?.headers,
                    error: mappedError,
                    logger: logger
                ) {
                    continue
                }

                throw mappedError
            }
        }
    }
}

// MARK: - Streaming Execution

extension RequestExecutor {
    func execute(
        _ onChunk: ChunkHandler
    ) async throws(NetSkeinError) -> (status: HTTPResponseStatus, headers: HTTPHeaders) {
        var attempt = 0

        while true {
            try checkCancellation()

            let (request, requestID) = try prepareRequest(attempt: attempt)
            let logger = prepareLogger(
                requestID: requestID,
                attempt: attempt,
                action: "outbound streaming request"
            )

            let startTime: DispatchTime = .now()
            var rawResponse: HTTPClientResponse?

            do {
                let response = try await client.underlyingClient.execute(
                    request,
                    timeout: timeout ?? .seconds(30),
                    logger: logger
                )
                rawResponse = response
                recordResponse(response, requestID: requestID, startTime: startTime, logger: logger)

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
            } catch {
                let mappedError = mapError(
                    error,
                    requestID: requestID,
                    action: "Streaming request",
                    logger: logger
                )

                if try await evaluateRetry(
                    policy: activeRetryPolicy,
                    attempt: &attempt,
                    status: rawResponse?.status,
                    headers: rawResponse?.headers,
                    error: mappedError,
                    logger: logger
                ) {
                    continue
                }

                throw mappedError
            }
        }
    }
}

// MARK: - File Download Execution

extension RequestExecutor {
    func execute(
        downloadTo path: String,
        resumption: DownloadResumption = .disabled,
        onProgress: DownloadProgress? = nil
    ) async throws(NetSkeinError) {
        var attempt = 0
        var activeValidator = resumption.validator

        if resumption == .disabled || resumption == .onRetry {
            if FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
        }

        while true {
            try checkCancellation()

            // Inspect existing file size if resumption is permitted
            let existingBytes: Int64
            if resumption != .disabled && FileManager.default.fileExists(atPath: path) {
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                existingBytes = (attributes?[.size] as? Int64) ?? 0
            } else {
                existingBytes = 0
            }

            // Inject Range & If-Range headers only when applicable (GET requests with existing bytes)
            let isResuming = existingBytes > 0 && method == .GET

            let (request, requestID) = try prepareRequest(attempt: attempt) { reqHeaders in
                if isResuming {
                    reqHeaders.replaceOrAdd(name: "Range", value: "bytes=\(existingBytes)-")
                    if let activeValidator {
                        reqHeaders.replaceOrAdd(name: "If-Range", value: activeValidator)
                    }
                }
            }

            let logger = prepareLogger(
                requestID: requestID,
                attempt: attempt,
                action: isResuming
                    ? "download resumption from byte \(existingBytes)"
                    : "file download"
            )

            let startTime = DispatchTime.now()
            var rawResponse: HTTPClientResponse?

            do {
                let response = try await client.underlyingClient.execute(
                    request,
                    timeout: timeout ?? .seconds(30),
                    logger: logger
                )
                rawResponse = response
                recordResponse(response, requestID: requestID, startTime: startTime, logger: logger)

                if let etag = response.headers.first(name: "ETag") {
                    activeValidator = etag
                } else if let lastModified = response.headers.first(name: "Last-Modified") {
                    activeValidator = lastModified
                }

                // Handle 416 Range Not Satisfiable: Reset file to 0 and retry cleanly
                if response.status == .rangeNotSatisfiable {
                    logger.warning("416 Range Not Satisfiable received. Truncating file to byte 0.")
                    FileManager.default.createFile(atPath: path, contents: nil)
                    activeValidator = nil
                    throw NetSkeinError.badStatus(response.status)
                }

                guard response.status.code >= 200 && response.status.code < 300 else {
                    throw NetSkeinError.badStatus(response.status)
                }

                try await writeResponseBodyToFile(
                    response: response,
                    path: path,
                    existingBytes: existingBytes,
                    logger: logger,
                    onProgress: onProgress
                )

                return
            } catch {
                let mappedError = mapError(
                    error,
                    requestID: requestID,
                    action: "Streaming download",
                    logger: logger
                )

                if try await evaluateRetry(
                    policy: activeRetryPolicy,
                    attempt: &attempt,
                    status: rawResponse?.status,
                    headers: rawResponse?.headers,
                    error: mappedError,
                    logger: logger
                ) {
                    continue
                }

                throw mappedError
            }
        }
    }
}
