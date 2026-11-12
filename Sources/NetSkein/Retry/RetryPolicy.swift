import NIOCore
import NIOHTTP1

/// Decides whether a failed attempt is retried, and how long to wait first.
///
/// Set one for every request with ``NetSkeinClientBuilder/retryPolicy(_:)``, or for one request
/// with ``NetSkeinRequest/retry(_:)``. Most apps use ``standard(maxRetries:backoff:retryNonIdempotent:maxRetryAfter:)``:
///
/// ```swift
/// let client = NetSkeinClient.builder()
///     .retryPolicy(.standard(maxRetries: 2))
///     .build()
/// ```
///
/// After each attempt, the client asks the ``evaluator`` whether to retry, unless the call has
/// already made ``maxRetries`` retries. It then waits as long as ``backoff`` says, or longer if the
/// response's `Retry-After` header asks for it. A retry is not made when:
///
/// - The server's `Retry-After` is longer than ``maxRetryAfter``.
/// - The wait would end after the call's ``NetSkeinRequest/callTimeout(_:)``.
/// - The caller has already received part of the response, such as a chunk from
///   ``NetSkeinRequest/stream(_:)``. Downloads are still retried, since
///   ``NetSkeinRequest/download(toFileAtPath:resumption:onProgress:)`` rewrites or resumes the
///   file.
///
/// The call then returns, or throws, what the last attempt produced.
///
/// ## Topics
///
/// ### Getting a Policy
///
/// - ``standard(maxRetries:backoff:retryNonIdempotent:maxRetryAfter:)``
/// - ``disabled``
/// - ``init(maxRetries:backoff:respectRetryAfterHeader:maxRetryAfter:evaluator:)``
///
/// ### Inspecting a Policy
///
/// - ``maxRetries``
/// - ``backoff``
/// - ``respectRetryAfterHeader``
/// - ``maxRetryAfter``
/// - ``evaluator``
/// - ``Evaluator``
public struct RetryPolicy: Sendable {
    /// Decides whether to retry an attempt described by a ``RetryContext``.
    public typealias Evaluator = @Sendable (RetryContext) async -> Bool

    /// The most retries a call makes, so a call makes at most `maxRetries + 1` attempts.
    public let maxRetries: Int
    /// How long to wait before each retry.
    public let backoff: BackoffStrategy
    /// Whether a response's `Retry-After` header can make the wait longer than ``backoff``.
    public let respectRetryAfterHeader: Bool
    /// The longest `Retry-After` worth waiting for. When a server asks for longer, the call
    /// gives up instead of retrying, and returns or throws what the last attempt produced.
    public let maxRetryAfter: TimeAmount
    /// Decides whether to retry each failed attempt.
    public let evaluator: Evaluator

    /// Creates a policy that retries whenever `evaluator` says to.
    ///
    /// The evaluator decides on every attempt, including ones that succeeded, so it must return
    /// `false` for responses you don't want retried.
    ///
    /// - Parameters:
    ///   - maxRetries: The most retries a call makes (default: 3).
    ///   - backoff: How long to wait before each retry
    ///     (default: ``BackoffStrategy/exponential(initial:multiplier:maxDelay:jitter:)``
    ///     with its defaults).
    ///   - respectRetryAfterHeader: Whether a response's `Retry-After` header can make the wait
    ///     longer (default: `true`).
    ///   - maxRetryAfter: The longest `Retry-After` worth waiting for (default: 60 seconds).
    ///   - evaluator: Decides whether to retry each attempt.
    public init(
        maxRetries: Int = 3,
        backoff: BackoffStrategy = .exponential(),
        respectRetryAfterHeader: Bool = true,
        maxRetryAfter: TimeAmount = .seconds(60),
        evaluator: @escaping Evaluator
    ) {
        self.maxRetries = maxRetries
        self.backoff = backoff
        self.respectRetryAfterHeader = respectRetryAfterHeader
        self.maxRetryAfter = maxRetryAfter
        self.evaluator = evaluator
    }
}

extension RetryPolicy {
    /// A policy that never retries.
    public static let disabled: Self = .init(maxRetries: 0) { _ in false }

    /// A policy that retries the failures most likely to succeed on a second try.
    ///
    /// It retries responses with status `408`, `429`, `500`, `502`, `503` or `504`, and errors
    /// of kind ``NetSkeinError/Kind/networkFailure``. It doesn't retry other errors, such as
    /// ``NetSkeinError/Kind/timedOut`` or ``NetSkeinError/Kind/circuitOpen``.
    ///
    /// It retries only idempotent methods, `GET`, `HEAD`, `PUT`, `DELETE`, `OPTIONS` and `TRACE`,
    /// unless `retryNonIdempotent` is `true`, since repeating a `POST` could repeat its effect.
    ///
    /// - Parameters:
    ///   - maxRetries: The most retries a call makes (default: 3).
    ///   - backoff: How long to wait before each retry
    ///     (default: ``BackoffStrategy/exponential(initial:multiplier:maxDelay:jitter:)``
    ///     with its defaults).
    ///   - retryNonIdempotent: Whether to retry methods such as `POST` and `PATCH` too
    ///     (default: `false`).
    ///   - maxRetryAfter: The longest `Retry-After` worth waiting for (default: 60 seconds).
    /// - Returns: The policy.
    public static func standard(
        maxRetries: Int = 3,
        backoff: BackoffStrategy = .exponential(),
        retryNonIdempotent: Bool = false,
        maxRetryAfter: TimeAmount = .seconds(60),
    ) -> Self {
        RetryPolicy(
            maxRetries: maxRetries,
            backoff: backoff,
            maxRetryAfter: maxRetryAfter
        ) { context in
            if context.attempt > context.maxRetries { return false }

            if !retryNonIdempotent && !context.method.isIdempotent {
                return false
            }

            if let status = context.responseStatus {
                switch status.code {
                case 408, 429, 500, 502, 503, 504:
                    return true
                default:
                    break
                }
            }

            if let error = context.error {
                return error.kind == .networkFailure
            }

            return false
        }
    }
}
