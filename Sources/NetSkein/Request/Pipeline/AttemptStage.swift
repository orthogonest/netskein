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
/// Never throws; every failure is reported in the ``AttemptOutcome`` for the retry stage to
/// judge.
struct AttemptStage: Sendable {
    let transport: any HTTPTransport
    let logger: Logger
    let method: HTTPMethod
    let url: String
    let headers: HTTPHeaders
    let body: BodySource
    let timeout: TimeAmount
    let middlewares: [any HTTPMiddleware]
    /// Sent as `X-Request-ID`; the same for every attempt of a call.
    let requestID: String

    func run<Operation: RequestOperation>(
        _ number: Int,
        of operation: inout Operation,
        span: (any Span)?
    ) async -> AttemptOutcome<Operation.Output> {
        let setup = operation.prepareAttempt()
        let head = prepareRequest(extraHeaders: setup.extraHeaders)
        let context = beginAttempt(number, description: setup.description)

        let startTime = DispatchTime.now()
        var response: HTTPClientResponse?
        do {
            let received = try await execute(head, context, action: operation.action)
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
                result: .failure(mapError(error, context, action: operation.action)),
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
    private func prepareRequest(extraHeaders: HTTPHeaders) -> RequestHead {
        var activeHeaders = headers

        activeHeaders.replaceOrAdd(name: "X-Request-ID", value: requestID)

        for (name, value) in extraHeaders {
            activeHeaders.replaceOrAdd(name: name, value: value)
        }

        return RequestHead(method: method, url: url, headers: activeHeaders)
    }

    /// Starts an attempt and logs that it is being initiated or retried.
    private func beginAttempt(_ number: Int, description: String) -> MiddlewareContext {
        var logger = logger
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
