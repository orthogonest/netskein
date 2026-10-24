import NIOCore

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

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
