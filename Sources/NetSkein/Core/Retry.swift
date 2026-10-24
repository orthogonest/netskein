import AsyncHTTPClient
import NIOCore
import NIOHTTP1

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public struct RetryContext: Sendable {
    public let attempt: Int  // 1-based attempt counter
    public let maxRetries: Int
    public let method: HTTPMethod
    public let url: String
    public let responseStatus: HTTPResponseStatus?
    public let responseHeaders: HTTPHeaders?
    public let error: NetSkeinError?
}

public enum BackoffStrategy: Sendable {
    case immediate
    case constant(TimeAmount)
    case exponential(
        initial: TimeAmount = .milliseconds(200),
        multiplier: Double = 2.0,
        maxDelay: TimeAmount = .seconds(30),
        jitter: Jitter = .full
    )

    public enum Jitter: Sendable {
        case none
        case full
        case equal
    }

    public func delay(forAttempt attempt: Int) -> TimeAmount {
        switch self {
        case .immediate:
            return .nanoseconds(0)

        case let .constant(amount):
            return amount

        case let .exponential(initial, multiplier, maxDelay, jitter):
            let exponential = pow(multiplier, Double(max(0, attempt - 1)))
            let initialNanos = Double(initial.nanoseconds)
            let maxNanos = Double(maxDelay.nanoseconds)
            let calculatedNanos = min(initialNanos * exponential, maxNanos)

            let finalNanos: Double
            switch jitter {
            case .none:
                finalNanos = calculatedNanos
            case .full:
                finalNanos = Double.random(in: 0...calculatedNanos)
            case .equal:
                let half = calculatedNanos / 2.0
                finalNanos = half + Double.random(in: 0...half)
            }

            return .nanoseconds(Int64(finalNanos))
        }
    }
}

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

extension HTTPMethod {
    var isIdempotent: Bool {
        switch self {
        case .GET, .HEAD, .PUT, .DELETE, .OPTIONS, .TRACE:
            return true
        default:
            return false
        }
    }
}

enum RetryAfterParser {
    static func parseDelay(from headers: HTTPHeaders?) -> TimeAmount? {
        guard let retryAfter = headers?.first(name: "Retry-After") else { return nil }

        if let seconds = Int64(retryAfter), seconds >= 0 {
            return .seconds(seconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        if let date = formatter.date(from: retryAfter) {
            let diff = date.timeIntervalSinceNow
            return diff > 0 ? .nanoseconds(Int64(diff * 1_000_000_000)) : .nanoseconds(0)
        }

        return nil
    }
}
