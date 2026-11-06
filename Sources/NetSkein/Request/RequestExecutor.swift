import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

/// Runs one call through the request pipeline:
///
/// ```
/// TracingStage    one span for the whole call                       (once per call)
///   RetryStage    retry policy, backoff, Retry-After, cancellation  (once per call)
///     AttemptStage  the operation, middleware and transport         (once per attempt)
/// ```
///
/// The operation (``SendOperation``, ``StreamOperation``, ``OpenStreamOperation`` or
/// ``DownloadOperation``) decides what each attempt does with its response, including reading
/// the body, so failures while reading it still reach the retry stage.
struct RequestExecutor: Sendable {
    let client: NetSkeinClient
    let method: HTTPMethod
    let url: String
    let headers: HTTPHeaders
    let body: BodySource
    let timeout: TimeAmount
    let retryPolicy: RetryPolicy
    let maxResponseBytes: Int
    let middlewares: [any HTTPMiddleware]
}

// MARK: - Pipeline

extension RequestExecutor {
    /// Sends the request until `operation` succeeds or the retry policy stops, all inside one
    /// span.
    private func run<Operation: RequestOperation>(
        _ operation: Operation
    ) async throws(NetSkeinError) -> Operation.Output {
        var operation = operation
        let requestID = UUID().uuidString

        let tracing = TracingStage(tracer: client.tracer, method: method)
        let retry = RetryStage(policy: retryPolicy, method: method, url: url)
        let attempts = AttemptStage(
            transport: client.transport,
            logger: client.logger,
            method: method,
            url: url,
            headers: headers,
            body: body,
            timeout: timeout,
            middlewares: middlewares,
            requestID: requestID
        )

        return try await tracing.run(
            operation.name,
            requestID: requestID
        ) { span throws(NetSkeinError) in
            try await retry.run(span: span) { number in
                await attempts.run(number, of: &operation, span: span)
            }
        }
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

    /// Sends the request and returns the response once its headers arrive, with the body still
    /// to be read; retries end there.
    func openStream() async throws(NetSkeinError) -> HTTPClientResponse {
        try await run(OpenStreamOperation())
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

// MARK: - Cancellation

func checkCancellation() throws(NetSkeinError) {
    if Task.isCancelled {
        throw .custom(
            kind: .networkFailure,
            message: "Task was cancelled before the request could complete.",
            underlyingError: CancellationError()
        )
    }
}
