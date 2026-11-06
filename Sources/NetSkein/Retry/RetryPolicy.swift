import NIOCore
import NIOHTTP1

public struct RetryPolicy: Sendable {
    public typealias Evaluator = @Sendable (RetryContext) async -> Bool

    public let maxRetries: Int
    public let backoff: BackoffStrategy
    public let respectRetryAfterHeader: Bool
    /// The longest `Retry-After` worth waiting for. When a server asks for longer, the call
    /// gives up instead of retrying, and returns or throws what the last attempt produced.
    public let maxRetryAfter: TimeAmount
    public let evaluator: Evaluator

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
    public static let disabled: Self = .init(maxRetries: 0) { _ in false }

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
