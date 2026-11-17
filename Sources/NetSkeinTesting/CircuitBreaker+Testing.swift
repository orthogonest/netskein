import NIOCore
import NetSkein

extension CircuitBreaker {
    /// A circuit breaker whose idea of the current time comes from `clock`, so tests can end an
    /// open period by advancing it instead of waiting.
    ///
    /// The other parameters mean the same as in
    /// `CircuitBreaker.init(failureThreshold:openDuration:halfOpenMaxRequests:key:isFailure:)`,
    /// and have the same defaults.
    ///
    /// - Parameters:
    ///   - clock: Where the circuit breaker reads the current time.
    ///   - failureThreshold: Failures in a row that open a circuit (default: 5).
    ///   - openDuration: How long an open circuit rejects requests before allowing a trial
    ///     (default: 30 seconds). Advance `clock` past it to allow the trial.
    ///   - halfOpenMaxRequests: Trial requests allowed at the same time while half-open
    ///     (default: 1).
    ///   - key: Names the circuit a request belongs to (default: one circuit per server).
    ///   - isFailure: Whether an attempt counts as a failure (default: network failures and
    ///     `500`, `502`, `503` and `504`).
    /// - Returns: The circuit breaker.
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
