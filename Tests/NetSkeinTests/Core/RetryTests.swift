import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
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

struct RetryPolicyTests {
    @Test(
        "RetryPolicyTests: Verifies isIdempotent returns true only for RFC 9110 idempotent methods"
    )
    func testHTTPMethodIdempotency() {
        // Idempotent methods
        #expect(HTTPMethod.GET.isIdempotent == true)
        #expect(HTTPMethod.HEAD.isIdempotent == true)
        #expect(HTTPMethod.PUT.isIdempotent == true)
        #expect(HTTPMethod.DELETE.isIdempotent == true)
        #expect(HTTPMethod.OPTIONS.isIdempotent == true)
        #expect(HTTPMethod.TRACE.isIdempotent == true)

        // Non-idempotent methods
        #expect(HTTPMethod.POST.isIdempotent == false)
        #expect(HTTPMethod.PATCH.isIdempotent == false)
        #expect(HTTPMethod.CONNECT.isIdempotent == false)
        #expect(HTTPMethod.RAW(value: "CUSTOM").isIdempotent == false)
    }

    @Test("RetryPolicyTests: Verifies RetryPolicy.none never permits retry")
    func testRetryPolicyNone() async {
        let policy = RetryPolicy.disabled
        #expect(policy.maxRetries == 0)

        let context = makeContext(
            attempt: 1,
            maxRetries: 0,
            method: .GET,
            error: .simple(.networkFailure)
        )
        let shouldRetry = await policy.evaluator(context)
        #expect(shouldRetry == false)
    }

    @Test(
        "RetryPolicyTests: Verifies standard policy rejects retry when attempts exceed maxRetries"
    )
    func testStandardPolicyExhaustion() async {
        let policy = RetryPolicy.standard(maxRetries: 3)

        // Attempt 4 > maxRetries 3
        let context = makeContext(
            attempt: 4,
            maxRetries: 3,
            method: .GET,
            error: .simple(.networkFailure)
        )
        let shouldRetry = await policy.evaluator(context)
        #expect(shouldRetry == false)
    }

    @Test(
        "RetryPolicyTests: Verifies standard policy guards non-idempotent methods unless explicitly enabled"
    )
    func testStandardPolicyIdempotencyGuard() async {
        let defaultPolicy = RetryPolicy.standard(maxRetries: 3, retryNonIdempotent: false)

        // POST should not retry by default even on network failure
        let postContext = makeContext(
            attempt: 1,
            maxRetries: 3,
            method: .POST,
            error: .simple(.networkFailure)
        )
        let shouldRetryDefault = await defaultPolicy.evaluator(postContext)
        #expect(shouldRetryDefault == false)

        // When retryNonIdempotent is enabled, POST is permitted to retry on network failure
        let allowNonIdempotentPolicy = RetryPolicy.standard(maxRetries: 3, retryNonIdempotent: true)
        let shouldRetryAllowed = await allowNonIdempotentPolicy.evaluator(postContext)
        #expect(shouldRetryAllowed == true)
    }

    @Test(
        "RetryPolicyTests: Verifies standard policy retries network failures and rejects client-side errors"
    )
    func testStandardPolicyErrorEvaluation() async {
        let policy = RetryPolicy.standard(maxRetries: 3)

        // Network failure -> Should retry
        let networkContext = makeContext(
            attempt: 1,
            maxRetries: 3,
            method: .GET,
            error: .simple(.networkFailure)
        )
        #expect(await policy.evaluator(networkContext) == true)

        // Invalid payload error -> Should not retry
        let payloadContext = makeContext(
            attempt: 1,
            maxRetries: 3,
            method: .GET,
            error: .simple(.invalidPayload)
        )
        #expect(await policy.evaluator(payloadContext) == false)

        // Local I/O error -> Should not retry
        let ioContext = makeContext(
            attempt: 1,
            maxRetries: 3,
            method: .GET,
            error: .simple(.ioFailure)
        )
        #expect(await policy.evaluator(ioContext) == false)
    }

    @Test(
        "RetryPolicyTests: Verifies standard policy retries transient HTTP status codes and rejects others"
    )
    func testStandardPolicyStatusEvaluation() async {
        let policy = RetryPolicy.standard(maxRetries: 3)

        // Eligible transient status codes (408, 429, 500, 502, 503, 504)
        let eligibleStatuses: [HTTPResponseStatus] = [
            .requestTimeout,  // 408
            .tooManyRequests,  // 429
            .internalServerError,  // 500
            .badGateway,  // 502
            .serviceUnavailable,  // 503
            .gatewayTimeout,  // 504
        ]

        for status in eligibleStatuses {
            let context = makeContext(attempt: 1, maxRetries: 3, method: .GET, status: status)
            #expect(await policy.evaluator(context) == true)
        }

        // Non-eligible status codes
        let nonEligibleStatuses: [HTTPResponseStatus] = [
            .ok,  // 200
            .badRequest,  // 400
            .unauthorized,  // 401
            .forbidden,  // 403
            .notFound,  // 404
            .unprocessableEntity,  // 422
        ]

        for status in nonEligibleStatuses {
            let context = makeContext(attempt: 1, maxRetries: 3, method: .GET, status: status)
            #expect(await policy.evaluator(context) == false)
        }

        // Neither error nor status -> Should not retry
        let emptyContext = makeContext(attempt: 1, maxRetries: 3, method: .GET)
        #expect(await policy.evaluator(emptyContext) == false)
    }

    @Test("RetryAfterParser: Verifies parsing delta-seconds format")
    func testRetryAfterSeconds() {
        var headers = HTTPHeaders()
        headers.add(name: "Retry-After", value: "120")
        #expect(RetryAfterParser.parseDelay(from: headers) == .seconds(120))

        headers.replaceOrAdd(name: "Retry-After", value: "0")
        #expect(RetryAfterParser.parseDelay(from: headers) == .seconds(0))
    }

    @Test("RetryAfterParser: Verifies parsing HTTP-Date format for future and past dates")
    func testRetryAfterHTTPDate() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        // 1. Future date (+60 seconds)
        let futureDate = Date().addingTimeInterval(60)
        var headers = HTTPHeaders()
        headers.add(name: "Retry-After", value: formatter.string(from: futureDate))

        let parsedDelay = RetryAfterParser.parseDelay(from: headers)
        #expect(parsedDelay != nil)
        #expect((parsedDelay?.nanoseconds ?? 0) > 0)
        #expect((parsedDelay?.nanoseconds ?? 0) <= TimeAmount.seconds(65).nanoseconds)

        // 2. Past date (-60 seconds) -> Clamped to 0
        let pastDate = Date().addingTimeInterval(-60)
        headers.replaceOrAdd(name: "Retry-After", value: formatter.string(from: pastDate))
        #expect(RetryAfterParser.parseDelay(from: headers) == .nanoseconds(0))
    }

    @Test("RetryAfterParser: Verifies returns nil for missing, negative, or malformed headers")
    func testRetryAfterInvalidHeaders() {
        // Missing header
        #expect(RetryAfterParser.parseDelay(from: nil) == nil)
        #expect(RetryAfterParser.parseDelay(from: HTTPHeaders()) == nil)

        // Negative integer
        var headers = HTTPHeaders()
        headers.add(name: "Retry-After", value: "-10")
        #expect(RetryAfterParser.parseDelay(from: headers) == nil)

        // Malformed non-numeric text
        headers.replaceOrAdd(name: "Retry-After", value: "invalid-value")
        #expect(RetryAfterParser.parseDelay(from: headers) == nil)
    }
}

// MARK: - Test Helpers

extension RetryPolicyTests {
    fileprivate func makeContext(
        attempt: Int,
        maxRetries: Int,
        method: HTTPMethod,
        url: String = "https://api.example.com/test",
        status: HTTPResponseStatus? = nil,
        headers: HTTPHeaders? = nil,
        error: NetSkeinError? = nil
    ) -> RetryContext {
        RetryContext(
            attempt: attempt,
            maxRetries: maxRetries,
            method: method,
            url: url,
            responseStatus: status,
            responseHeaders: headers,
            error: error
        )
    }
}
