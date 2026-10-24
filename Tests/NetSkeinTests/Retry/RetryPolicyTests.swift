import NIOHTTP1
import Testing

@testable import NetSkein

struct RetryPolicyTests {
    @Test("RetryPolicyTests: Verifies RetryPolicy.disabled never permits retry")
    func testRetryPolicyDisabled() async {
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
}

// MARK: - Test Helpers

extension RetryPolicyTests {
    private func makeContext(
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
