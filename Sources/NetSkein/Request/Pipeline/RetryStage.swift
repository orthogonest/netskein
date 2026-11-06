import Foundation
import Logging
import NIOCore
import NIOHTTP1
import Tracing

/// What one attempt produced, as far as the retry stage needs to know.
struct AttemptOutcome<Output> {
    var result: Result<Output, NetSkeinError>
    /// The response head, when one arrived before the attempt finished or failed.
    var status: HTTPResponseStatus?
    var headers: HTTPHeaders?
    /// Whether the retry policy may be asked about this attempt at all.
    ///
    /// `false` once the caller has seen part of the response, or after a successful
    /// non-buffered call, whose response the caller already has.
    var isRetryable: Bool
    /// The attempt's logger, already tagged with its request metadata.
    var logger: Logger
}

/// Makes attempts until one succeeds or the retry policy stops, backing off between them.
///
/// Knows nothing about requests, middleware or response bodies: each attempt is a closure that
/// reports an ``AttemptOutcome``.
struct RetryStage: Sendable {
    let policy: RetryPolicy
    let method: HTTPMethod
    let url: String

    func run<Output>(
        span: (any Span)?,
        _ attempt: (Int) async -> AttemptOutcome<Output>
    ) async throws(NetSkeinError) -> Output {
        try await makeAttempt(0, span: span, attempt)
    }

    /// Makes attempt `number`, then either finishes the call or backs off and makes the next one.
    private func makeAttempt<Output>(
        _ number: Int,
        span: (any Span)?,
        _ attempt: (Int) async -> AttemptOutcome<Output>
    ) async throws(NetSkeinError) -> Output {
        try checkCancellation()
        if number > 0 {
            span?.attributes["http.request.resend_count"] = number
        }

        let outcome = await attempt(number)
        guard outcome.isRetryable, await shouldRetry(after: number, outcome) else {
            return try outcome.result.get()
        }

        try await backOff(before: number + 1, responseHeaders: outcome.headers)
        return try await makeAttempt(number + 1, span: span, attempt)
    }

    /// Asks the retry policy whether attempt `number` should be followed by another one.
    private func shouldRetry<Output>(
        after number: Int,
        _ outcome: AttemptOutcome<Output>
    ) async -> Bool {
        let nextNumber = number + 1

        let error: NetSkeinError? =
            switch outcome.result {
            case .success: nil
            case let .failure(failure): failure
            }

        let retryContext = RetryContext(
            attempt: nextNumber,
            maxRetries: policy.maxRetries,
            method: method,
            url: url,
            responseStatus: outcome.status,
            responseHeaders: outcome.headers,
            error: error
        )

        guard await policy.evaluator(retryContext), nextNumber <= policy.maxRetries else {
            return false
        }

        outcome.logger.warning(
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
