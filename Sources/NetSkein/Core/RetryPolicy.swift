public struct RetryPolicy: Sendable {
    public typealias Evaluator = @Sendable (RetryContext) async -> Bool

    public let maxRetries: Int
    public let backoff: BackoffStrategy
    public let respectRetryAfterHeader: Bool
    public let evaluator: Evaluator

    public init(
        maxRetries: Int = 3,
        backoff: BackoffStrategy = .exponential(),
        respectRetryAfterHeader: Bool = true,
        evaluator: @escaping Evaluator
    ) {
        self.maxRetries = maxRetries
        self.backoff = backoff
        self.respectRetryAfterHeader = respectRetryAfterHeader
        self.evaluator = evaluator
    }
}

extension RetryPolicy {
    public static let disabled: Self = .init(maxRetries: 0) { _ in false }

    public static func standard(
        maxRetries: Int = 3,
        backoff: BackoffStrategy = .exponential(),
        retryNonIdempotent: Bool = false,
    ) -> Self {
        Self(maxRetries: maxRetries, backoff: backoff) { context in
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
