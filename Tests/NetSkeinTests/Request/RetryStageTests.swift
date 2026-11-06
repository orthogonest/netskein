import Logging
import NIOCore
import NIOHTTP1
import Testing

@testable import NetSkein
@testable import NetSkeinTesting

/// The retry stage on its own: each attempt is a closure, so no transport or middleware is
/// involved.
struct RetryStageTests {
    let logger = Logger(label: LoggerLabel.test)
    let head = RequestHead(method: .GET, url: "https://api.example.com", headers: [:])

    func makeStage(
        maxRetries: Int = 3,
        maxRetryAfter: TimeAmount = .seconds(60),
        deadline: NIODeadline? = nil
    ) -> RetryStage {
        RetryStage(
            policy: .standard(
                maxRetries: maxRetries,
                backoff: .immediate,
                maxRetryAfter: maxRetryAfter
            ),
            deadline: deadline
        )
    }

    func failure(retryable: Bool = true) -> AttemptOutcome<String> {
        AttemptOutcome(
            result: .failure(.custom(kind: .networkFailure, message: "dropped")),
            isRetryable: retryable,
            logger: logger
        )
    }

    func success(
        _ value: String,
        status: HTTPResponseStatus = .ok,
        headers: HTTPHeaders = [:]
    ) -> AttemptOutcome<String> {
        AttemptOutcome(
            result: .success(value),
            status: status,
            headers: headers,
            isRetryable: true,
            logger: logger
        )
    }
}

extension RetryStageTests {
    @Test("RetryStageTests: failed attempts are retried until one succeeds")
    func testRetriesUntilSuccess() async throws {
        var numbers: [Int] = []

        let result = try await makeStage()
            .run(head, span: nil) { number in
                numbers.append(number)
                return number < 2 ? failure() : success("done")
            }

        #expect(result == "done")
        #expect(numbers == [0, 1, 2])
    }

    @Test("RetryStageTests: an attempt that cannot be retried ends the call with its error")
    func testNotRetryable() async {
        var count = 0

        await #expect(throws: NetSkeinError.self) {
            _ = try await makeStage()
                .run(head, span: nil) { _ in
                    count += 1
                    return failure(retryable: false)
                }
        }
        #expect(count == 1)
    }

    @Test("RetryStageTests: the call fails with the last error once maxRetries is used up")
    func testMaxRetries() async {
        var count = 0

        await #expect(throws: NetSkeinError.self) {
            _ = try await makeStage(maxRetries: 2)
                .run(head, span: nil) { _ in
                    count += 1
                    return failure()
                }
        }
        #expect(count == 3)
    }

    @Test("RetryStageTests: a successful attempt with a retryable status is retried")
    func testRetryableStatus() async throws {
        let result = try await makeStage()
            .run(head, span: nil) { number in
                number == 0 ? success("busy", status: .serviceUnavailable) : success("done")
            }

        #expect(result == "done")
    }
}

// MARK: - Retry-After

extension RetryStageTests {
    @Test(
        "RetryStageTests: a Retry-After longer than maxRetryAfter ends the call with the last result"
    )
    func testRetryAfterOverLimit() async throws {
        var count = 0

        let result = try await makeStage(maxRetryAfter: .seconds(10))
            .run(head, span: nil) { _ in
                count += 1
                return success(
                    "busy",
                    status: .serviceUnavailable,
                    headers: ["Retry-After": "11"]
                )
            }

        #expect(result == "busy")
        #expect(count == 1)
    }

    @Test("RetryStageTests: a Retry-After within maxRetryAfter is waited for, then retried")
    func testRetryAfterWithinLimit() async throws {
        let result = try await makeStage(maxRetryAfter: .zero)
            .run(head, span: nil) { number in
                number == 0
                    ? success("busy", status: .serviceUnavailable, headers: ["Retry-After": "0"])
                    : success("done")
            }

        #expect(result == "done")
    }
}

// MARK: - Call Timeout

extension RetryStageTests {
    @Test(
        "RetryStageTests: a retry whose wait would pass the deadline ends the call with the last result"
    )
    func testDeadlineStopsRetry() async throws {
        var count = 0

        let result = try await makeStage(deadline: .now() + .milliseconds(100))
            .run(head, span: nil) { _ in
                count += 1
                return success(
                    "busy",
                    status: .serviceUnavailable,
                    headers: ["Retry-After": "1"]
                )
            }

        #expect(result == "busy")
        #expect(count == 1)
    }
}
