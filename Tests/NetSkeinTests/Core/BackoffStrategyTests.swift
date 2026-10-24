import NIOCore
import Testing

@testable import NetSkein

struct BackoffStrategyTests {
    @Test("BackoffStrategyTests: Verifies immediate backoff strategy returns zero delay")
    func testImmediateBackoff() {
        let strategy = BackoffStrategy.immediate
        #expect(strategy.delay(forAttempt: 1) == .nanoseconds(0))
        #expect(strategy.delay(forAttempt: 5) == .nanoseconds(0))
    }

    @Test(
        "BackoffStrategyTests: Verifies constant backoff strategy returns identical delay for all attempts"
    )
    func testConstantBackoff() {
        let expectedDelay: TimeAmount = .milliseconds(500)
        let strategy = BackoffStrategy.constant(expectedDelay)

        #expect(strategy.delay(forAttempt: 1) == expectedDelay)
        #expect(strategy.delay(forAttempt: 3) == expectedDelay)
        #expect(strategy.delay(forAttempt: 10) == expectedDelay)
    }

    @Test(
        "BackoffStrategyTests: Verifies exponential backoff with no jitter produces exact exponential values"
    )
    func testExponentialBackoffNoJitter() {
        let strategy = BackoffStrategy.exponential(
            initial: .milliseconds(100),
            multiplier: 2.0,
            maxDelay: .seconds(10),
            jitter: .none
        )

        // Attempt 1: 100ms * (2^0) = 100ms
        #expect(strategy.delay(forAttempt: 1) == .milliseconds(100))

        // Attempt 2: 100ms * (2^1) = 200ms
        #expect(strategy.delay(forAttempt: 2) == .milliseconds(200))

        // Attempt 3: 100ms * (2^2) = 400ms
        #expect(strategy.delay(forAttempt: 3) == .milliseconds(400))

        // Attempt 0 or negative (edge cases): clamped to attempt 1
        #expect(strategy.delay(forAttempt: 0) == .milliseconds(100))
        #expect(strategy.delay(forAttempt: -1) == .milliseconds(100))
    }

    @Test("BackoffStrategyTests: Verifies exponential backoff respects maxDelay clamping")
    func testExponentialBackoffClamping() {
        let maxDelay: TimeAmount = .seconds(1)
        let strategy = BackoffStrategy.exponential(
            initial: .milliseconds(400),
            multiplier: 2.0,
            maxDelay: maxDelay,
            jitter: .none
        )

        // Attempt 1: 400ms
        #expect(strategy.delay(forAttempt: 1) == .milliseconds(400))

        // Attempt 2: 800ms
        #expect(strategy.delay(forAttempt: 2) == .milliseconds(800))

        // Attempt 3: 1600ms -> Clamped to maxDelay (1000ms)
        #expect(strategy.delay(forAttempt: 3) == maxDelay)

        // Attempt 10: Clamped to maxDelay (1000ms)
        #expect(strategy.delay(forAttempt: 10) == maxDelay)
    }

    @Test(
        "BackoffStrategyTests: Verifies full jitter produces values between 0 and calculated exponential delay"
    )
    func testExponentialBackoffFullJitter() {
        let strategy = BackoffStrategy.exponential(
            initial: .milliseconds(200),
            multiplier: 2.0,
            maxDelay: .seconds(5),
            jitter: .full
        )

        let delayNanos = strategy.delay(forAttempt: 2).nanoseconds
        let maxPossibleNanos = TimeAmount.milliseconds(400).nanoseconds

        #expect(delayNanos >= 0)
        #expect(delayNanos <= maxPossibleNanos)
    }

    @Test(
        "BackoffStrategyTests: Verifies equal jitter produces values between half and calculated exponential delay"
    )
    func testExponentialBackoffEqualJitter() {
        let strategy = BackoffStrategy.exponential(
            initial: .milliseconds(200),
            multiplier: 2.0,
            maxDelay: .seconds(5),
            jitter: .equal
        )

        let delayNanos = strategy.delay(forAttempt: 2).nanoseconds
        let halfNanos = TimeAmount.milliseconds(200).nanoseconds
        let maxPossibleNanos = TimeAmount.milliseconds(400).nanoseconds

        #expect(delayNanos >= halfNanos)
        #expect(delayNanos <= maxPossibleNanos)
    }
}
