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
/// Knows nothing about middleware, transports or response bodies: each attempt is a closure
/// that reports an ``AttemptOutcome``. Of the request, only its method and URL are used, to tell
/// the retry policy what is being retried.
struct RetryStage: Sendable {
    let policy: RetryPolicy
    /// When the call's ``NetSkeinRequest/callTimeout(_:)`` ends, or `nil` without one. A retry
    /// whose wait would end after it is not made.
    let deadline: NIODeadline?

    /// Makes attempts at `head`, as left by the middleware that runs once per call.
    func run<Output>(
        _ head: RequestHead,
        span: (any Span)?,
        _ attempt: (Int) async -> AttemptOutcome<Output>
    ) async throws(NetSkeinError) -> Output {
        try await makeAttempt(0, at: head, span: span, attempt)
    }

    /// Makes attempt `number`, then either finishes the call or backs off and makes the next one.
    private func makeAttempt<Output>(
        _ number: Int,
        at head: RequestHead,
        span: (any Span)?,
        _ attempt: (Int) async -> AttemptOutcome<Output>
    ) async throws(NetSkeinError) -> Output {
        try checkCancellation()
        if number > 0 {
            span?.attributes["http.request.resend_count"] = number
        }

        let outcome = await attempt(number)
        guard
            outcome.isRetryable,
            await shouldRetry(head, after: number, outcome),
            let delay = retryDelay(before: number + 1, after: outcome)
        else {
            return try outcome.result.get()
        }

        outcome.logger.warning(
            "Request eligible for retry. Backing off before attempt \(number + 2)",
            metadata: [
                "attempt": .string("\(number + 1)"),
                "max_retries": .string("\(policy.maxRetries)"),
            ]
        )

        try await sleep(for: delay)

        return try await makeAttempt(number + 1, at: head, span: span, attempt)
    }

    /// Asks the retry policy whether attempt `number` at `head` should be followed by another
    /// one.
    private func shouldRetry<Output>(
        _ head: RequestHead,
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
            method: head.method,
            url: head.url,
            responseStatus: outcome.status,
            responseHeaders: outcome.headers,
            error: error
        )

        return await policy.evaluator(retryContext) && nextNumber <= policy.maxRetries
    }

    /// How long to wait before attempt `number`: the policy's backoff, or a longer
    /// `Retry-After`. `nil` when the server asks to wait longer than `maxRetryAfter`, or when the
    /// wait would end after the call's deadline, which ends the call instead.
    private func retryDelay<Output>(
        before number: Int,
        after outcome: AttemptOutcome<Output>
    ) -> TimeAmount? {
        guard let delay = requestedDelay(before: number, after: outcome) else { return nil }

        if let deadline, NIODeadline.now() + delay > deadline {
            outcome.logger.warning(
                "Waiting for the next attempt would pass the call timeout. Giving up"
            )
            return nil
        }
        return delay
    }

    /// The policy's backoff before attempt `number`, or a longer `Retry-After`. `nil` when the
    /// server asks to wait longer than `maxRetryAfter`.
    private func requestedDelay<Output>(
        before number: Int,
        after outcome: AttemptOutcome<Output>
    ) -> TimeAmount? {
        let backoff = policy.backoff.delay(forAttempt: number)

        guard
            policy.respectRetryAfterHeader,
            let retryAfter = RetryAfterParser.parseDelay(from: outcome.headers)
        else { return backoff }

        guard retryAfter <= policy.maxRetryAfter else {
            outcome.logger.warning(
                "Server asked to retry after longer than maxRetryAfter. Giving up",
                metadata: [
                    "retry_after_seconds": .string("\(retryAfter.nanoseconds / 1_000_000_000)"),
                    "max_retry_after_seconds": .string(
                        "\(policy.maxRetryAfter.nanoseconds / 1_000_000_000)"
                    ),
                ]
            )
            return nil
        }

        return max(backoff, retryAfter)
    }

    private func sleep(for delay: TimeAmount) async throws(NetSkeinError) {
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
