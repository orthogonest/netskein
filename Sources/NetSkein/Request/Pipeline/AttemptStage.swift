import AsyncHTTPClient
import Dispatch
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import Tracing

/// Makes one attempt: prepares the request for the operation, sends it through the middleware
/// and transport, and lets the operation handle the response, body included.
///
/// Never throws. Every failure is reported in the ``AttemptOutcome`` for the retry stage to
/// judge.
struct AttemptStage: Sendable {
    let transport: any HTTPTransport
    let logger: Logger
    let body: BodySource
    let timeout: TimeAmount
    let middlewares: [any HTTPMiddleware]
    /// Sent as `X-Request-ID`. The same for every attempt of a call.
    let requestID: String

    /// Makes attempt `number` at `head`, as left by the middleware that runs once per call.
    func run<Operation: RequestOperation>(
        _ number: Int,
        at head: RequestHead,
        of operation: inout Operation,
        span: (any Span)?
    ) async -> AttemptOutcome<Operation.Output> {
        let setup = operation.prepareAttempt()
        let context = beginAttempt(number, at: head, description: setup.description)
        let attemptHead = prepareRequest(head, extraHeaders: setup.extraHeaders)

        let startTime = DispatchTime.now()
        var response: HTTPClientResponse?
        do {
            let received = try await execute(attemptHead, context, action: operation.action)
            response = received
            span?.attributes["http.response.status_code"] = Int(received.status.code)
            if let cacheStatus = received.headers.netSkeinCacheStatus {
                span?.attributes["netskein.cache_status"] = cacheStatus
            }
            recordResponse(received, context, startedAt: startTime)

            let output = try await operation.handle(received, logger: context.logger)
            return AttemptOutcome(
                result: .success(output),
                status: received.status,
                headers: received.headers,
                isRetryable: operation.isBuffered,
                logger: context.logger
            )
        } catch {
            return AttemptOutcome(
                result: .failure(context.netSkeinError(from: error, action: operation.action)),
                status: response?.status,
                headers: response?.headers,
                isRetryable: !operation.hasDeliveredData,
                logger: context.logger
            )
        }
    }
}

// MARK: - Request Preparation

extension AttemptStage {
    /// `head` with the request ID and the headers the operation adds for this attempt.
    private func prepareRequest(_ head: RequestHead, extraHeaders: HTTPHeaders) -> RequestHead {
        var activeHeaders = head.headers

        activeHeaders.replaceOrAdd(name: "X-Request-ID", value: requestID)

        for (name, value) in extraHeaders {
            activeHeaders.replaceOrAdd(name: name, value: value)
        }

        return RequestHead(method: head.method, url: head.url, headers: activeHeaders)
    }

    /// Starts an attempt and logs that it is being initiated or retried.
    private func beginAttempt(
        _ number: Int,
        at head: RequestHead,
        description: String
    ) -> MiddlewareContext {
        var logger = logger.tagged(requestID: requestID, head: head)
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
}

// MARK: - Middleware and Transport

extension AttemptStage {
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
                return try await transport.execute(
                    request,
                    timeout: timeout,
                    logger: context.logger
                )
            } catch {
                throw context.netSkeinError(from: error, action: action)
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

        var metadata: Logger.Metadata = [
            "request_id": .string(activeResponseID),
            "status_code": .string("\(response.status.code)"),
            "duration_seconds": .string(String(format: "%.4f", duration)),
        ]
        if let cacheStatus = response.headers.netSkeinCacheStatus {
            metadata["cache_status"] = .string(cacheStatus)
        }
        context.logger.info("Response received", metadata: metadata)
    }
}

// MARK: - Shared With CallStage

extension Logger {
    /// The logger tagged with the request's ID, method and URL.
    func tagged(requestID: String, head: RequestHead) -> Logger {
        var logger = self
        logger[metadataKey: "request_id"] = .string(requestID)
        logger[metadataKey: "http_method"] = .string(head.method.rawValue)
        logger[metadataKey: "url"] = .string(head.url)
        return logger
    }
}

extension MiddlewareContext {
    /// `error` as a ``NetSkeinError``: unchanged when it already is one, otherwise logged and
    /// reported as a network failure of `action`.
    func netSkeinError(from error: any Error, action: String) -> NetSkeinError {
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
