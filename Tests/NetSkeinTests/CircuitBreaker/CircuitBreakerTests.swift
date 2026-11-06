import Foundation
import Logging
import NIOCore
import NIOHTTP1
import Testing

@testable import NetSkein
@testable import NetSkeinTesting

/// The breaker's state machine on its own, driven by a test clock.
struct CircuitBreakerTests {
    let logger = Logger(label: LoggerLabel.test)
    let key = "https://api.example.com"
    let serverFailure: Result<HTTPResponseStatus, NetSkeinError> = .success(.serviceUnavailable)
    let ok: Result<HTTPResponseStatus, NetSkeinError> = .success(.ok)

    /// Sends `count` requests through `breaker` that end with `outcome`.
    func send(
        _ count: Int,
        _ outcome: Result<HTTPResponseStatus, NetSkeinError>,
        through breaker: CircuitBreaker
    ) throws {
        for _ in 0..<count {
            let permit = try breaker.acquire(key, logger: logger)
            breaker.record(outcome, for: permit, logger: logger)
        }
    }

    func isRejected(_ breaker: CircuitBreaker) -> Bool {
        do {
            _ = try breaker.acquire(key, logger: logger)
            return false
        } catch {
            return error.kind == .circuitOpen
        }
    }
}

// MARK: - Opening

extension CircuitBreakerTests {
    @Test("CircuitBreakerTests: failures in a row open the circuit until openDuration passes")
    func testOpens() throws {
        let clock = TestClock()
        let breaker = CircuitBreaker.testing(clock: clock, failureThreshold: 3)

        try send(2, serverFailure, through: breaker)
        #expect(breaker.state(for: key) == .closed)

        try send(1, serverFailure, through: breaker)
        #expect(breaker.state(for: key) == .open(until: clock.now.addingTimeInterval(30)))
        #expect(isRejected(breaker))
    }

    @Test("CircuitBreakerTests: a success resets the count of failures in a row")
    func testSuccessResetsCount() throws {
        let breaker = CircuitBreaker.testing(clock: TestClock(), failureThreshold: 3)

        try send(2, serverFailure, through: breaker)
        try send(1, ok, through: breaker)
        try send(2, serverFailure, through: breaker)

        #expect(breaker.state(for: key) == .closed)
    }

    @Test("CircuitBreakerTests: thresholds below 1 are treated as 1")
    func testThresholdsClamped() throws {
        let clock = TestClock()
        let breaker = CircuitBreaker.testing(
            clock: clock,
            failureThreshold: 0,
            halfOpenMaxRequests: 0
        )

        try send(1, serverFailure, through: breaker)
        #expect(isRejected(breaker))

        clock.advance(by: .seconds(30))
        _ = try breaker.acquire(key, logger: logger)
        #expect(isRejected(breaker))
    }

    @Test("CircuitBreakerTests: each key has its own circuit")
    func testKeysAreSeparate() throws {
        let breaker = CircuitBreaker.testing(clock: TestClock(), failureThreshold: 1)

        try send(1, serverFailure, through: breaker)

        #expect(breaker.state(for: key) != .closed)
        #expect(breaker.state(for: "https://other.example.com") == .closed)
    }
}

// MARK: - Half-Open

extension CircuitBreakerTests {
    @Test("CircuitBreakerTests: after openDuration a trial is let through, and its success closes")
    func testTrialSuccessCloses() throws {
        let clock = TestClock()
        let breaker = CircuitBreaker.testing(clock: clock, failureThreshold: 1)
        try send(1, serverFailure, through: breaker)

        clock.advance(by: .seconds(30))
        let trial = try breaker.acquire(key, logger: logger)

        #expect(trial.isTrial)
        #expect(breaker.state(for: key) == .halfOpen)
        #expect(isRejected(breaker))

        breaker.record(ok, for: trial, logger: logger)
        #expect(breaker.state(for: key) == .closed)
    }

    @Test("CircuitBreakerTests: a failed trial opens the circuit again for another openDuration")
    func testTrialFailureReopens() throws {
        let clock = TestClock()
        let breaker = CircuitBreaker.testing(clock: clock, failureThreshold: 1)
        try send(1, serverFailure, through: breaker)

        clock.advance(by: .seconds(30))
        let trial = try breaker.acquire(key, logger: logger)
        breaker.record(serverFailure, for: trial, logger: logger)

        #expect(breaker.state(for: key) == .open(until: clock.now.addingTimeInterval(30)))
    }

    @Test("CircuitBreakerTests: halfOpenMaxRequests trials may run at the same time")
    func testConcurrentTrials() throws {
        let clock = TestClock()
        let breaker = CircuitBreaker.testing(
            clock: clock,
            failureThreshold: 1,
            halfOpenMaxRequests: 2
        )
        try send(1, serverFailure, through: breaker)
        clock.advance(by: .seconds(30))

        let first = try breaker.acquire(key, logger: logger)
        let second = try breaker.acquire(key, logger: logger)

        #expect(first.isTrial && second.isTrial)
        #expect(isRejected(breaker))
    }

    @Test("CircuitBreakerTests: a released trial frees its place for another")
    func testReleaseTrial() throws {
        let clock = TestClock()
        let breaker = CircuitBreaker.testing(clock: clock, failureThreshold: 1)
        try send(1, serverFailure, through: breaker)
        clock.advance(by: .seconds(30))

        breaker.release(try breaker.acquire(key, logger: logger))

        #expect(try breaker.acquire(key, logger: logger).isTrial)
    }

    @Test("CircuitBreakerTests: releasing a request that is not a trial changes nothing")
    func testReleaseNonTrial() throws {
        let breaker = CircuitBreaker.testing(clock: TestClock(), failureThreshold: 2)
        try send(1, serverFailure, through: breaker)

        breaker.release(try breaker.acquire(key, logger: logger))
        try send(1, serverFailure, through: breaker)

        #expect(breaker.state(for: key) != .closed)
    }

    @Test("CircuitBreakerTests: results that arrive after the circuit changed are ignored")
    func testLateResultsIgnored() throws {
        let clock = TestClock()
        let breaker = CircuitBreaker.testing(clock: clock, failureThreshold: 1)

        // Let through while closed, finishing after the circuit opened
        let slow = try breaker.acquire(key, logger: logger)
        try send(1, serverFailure, through: breaker)
        breaker.record(ok, for: slow, logger: logger)
        #expect(breaker.state(for: key) != .closed)

        // Let through while closed, finishing while half-open
        clock.advance(by: .seconds(30))
        _ = try breaker.acquire(key, logger: logger)
        breaker.record(ok, for: slow, logger: logger)
        #expect(breaker.state(for: key) == .halfOpen)
    }

    @Test("CircuitBreakerTests: reset closes every circuit")
    func testReset() throws {
        let breaker = CircuitBreaker.testing(clock: TestClock(), failureThreshold: 1)
        try send(1, serverFailure, through: breaker)

        breaker.reset()

        #expect(breaker.state(for: key) == .closed)
    }
}

// MARK: - Defaults

extension CircuitBreakerTests {
    @Test(
        "CircuitBreakerTests: requests are grouped by origin",
        arguments: [
            ("https://API.example.com/users?page=2", "https://api.example.com"),
            ("http://api.example.com:8080/users", "http://api.example.com:8080"),
            ("//api.example.com/users", "://api.example.com"),
            ("/relative/path", "/relative/path"),
        ]
    )
    func testOrigin(url: String, origin: String) {
        let request = RequestHead(method: .GET, url: url, headers: [:])

        #expect(CircuitBreaker.origin(of: request) == origin)
    }

    @Test(
        "CircuitBreakerTests: network failures and 500, 502, 503, 504 count as failures",
        arguments: [
            (Result<HTTPResponseStatus, NetSkeinError>.success(.internalServerError), true),
            (.success(.badGateway), true),
            (.success(.serviceUnavailable), true),
            (.success(.gatewayTimeout), true),
            (.success(.ok), false),
            (.success(.notFound), false),
            (.success(.tooManyRequests), false),
            (.failure(.simple(.networkFailure)), true),
            (.failure(.simple(.invalidPayload)), false),
        ]
    )
    func testIsServerFailure(outcome: Result<HTTPResponseStatus, NetSkeinError>, expected: Bool) {
        #expect(CircuitBreaker.isServerFailure(outcome) == expected)
    }

    @Test("CircuitBreakerTests: the convenience initializer applies the documented defaults")
    func testDefaults() throws {
        let breaker = CircuitBreaker()

        #expect(breaker.failureThreshold == 5)
        #expect(breaker.openDuration == .seconds(30))
        #expect(breaker.halfOpenMaxRequests == 1)
        #expect(breaker.key(RequestHead(method: .GET, url: "\(key)/users", headers: [:])) == key)
        try send(5, serverFailure, through: breaker)
        #expect(breaker.state(for: key) != .closed)
    }
}
