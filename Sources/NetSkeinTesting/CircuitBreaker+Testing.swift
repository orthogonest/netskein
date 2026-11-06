import NIOCore
import NetSkein

extension CircuitBreaker {
    /// A circuit breaker whose idea of the current time comes from `clock`, so tests can end an
    /// open period by advancing it instead of waiting.
    ///
    /// The other parameters mean the same as in
    /// `CircuitBreaker.init(failureThreshold:openDuration:halfOpenMaxRequests:key:isFailure:)`,
    /// and have the same defaults.
    public static func testing(
        clock: TestClock,
        failureThreshold: Int = 5,
        openDuration: TimeAmount = .seconds(30),
        halfOpenMaxRequests: Int = 1,
        key: @escaping Key = CircuitBreaker.origin(of:),
        isFailure: @escaping FailureEvaluator = CircuitBreaker.isServerFailure(_:)
    ) -> CircuitBreaker {
        CircuitBreaker(
            failureThreshold: failureThreshold,
            openDuration: openDuration,
            halfOpenMaxRequests: halfOpenMaxRequests,
            key: key,
            isFailure: isFailure,
            now: { clock.now }
        )
    }
}
