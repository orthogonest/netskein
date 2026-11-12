import Foundation
import NIOCore

/// How long a ``RetryPolicy`` waits before each retry.
///
/// When the response has a `Retry-After` header that asks for longer, the policy waits that
/// long instead. See ``RetryPolicy/respectRetryAfterHeader``.
///
/// ## Topics
///
/// ### Strategies
///
/// - ``immediate``
/// - ``constant(_:)``
/// - ``exponential(initial:multiplier:maxDelay:jitter:)``
/// - ``Jitter``
///
/// ### Computing a Delay
///
/// - ``delay(forAttempt:)``
public enum BackoffStrategy: Sendable {
    /// Retries at once, without waiting.
    case immediate

    /// Waits the same time before every retry.
    case constant(TimeAmount)

    /// Waits `initial` before the first retry and `multiplier` times longer before each one
    /// after it, up to `maxDelay`, then applies `jitter`.
    ///
    /// With the defaults, retries wait up to 200 ms, 400 ms, 800 ms and so on, with full jitter.
    ///
    /// - Parameters:
    ///   - initial: The wait before the first retry, before jitter (default: 200 ms).
    ///   - multiplier: How much longer each wait is than the one before (default: 2).
    ///   - maxDelay: The longest wait, before jitter (default: 30 seconds).
    ///   - jitter: How the wait is randomized (default: ``Jitter/full``).
    case exponential(
        initial: TimeAmount = .milliseconds(200),
        multiplier: Double = 2.0,
        maxDelay: TimeAmount = .seconds(30),
        jitter: Jitter = .full
    )

    /// How an exponential wait is randomized, so that clients that failed together don't all
    /// retry at the same moment.
    public enum Jitter: Sendable {
        /// Waits exactly the computed time.
        case none
        /// Waits a random time between zero and the computed time.
        case full
        /// Waits a random time between half the computed time and all of it.
        case equal
    }

    /// The wait before retry number `attempt`.
    ///
    /// - Parameter attempt: The retry about to be made, starting at 1 for the first retry.
    /// - Returns: The wait, randomized when the strategy has jitter.
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
