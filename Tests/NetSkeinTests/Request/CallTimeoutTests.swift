import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import Testing

@testable import NetSkein
@testable import NetSkeinTesting

/// `callTimeout` limits the whole call. These tests use real, short timers.
struct CallTimeoutTests {
    let url = "https://api.example.com/slow"

    func kind(of error: any Error) -> NetSkeinError.Kind? {
        (error as? NetSkeinError)?.kind
    }
}

extension CallTimeoutTests {
    @Test("CallTimeoutTests: a call that takes longer than its limit is cancelled and times out")
    func testTimesOut() async {
        let client = NetSkeinClient.testing()
            .addStub(HTTPStub.get(url).delay(.seconds(5)).text("late"))
            .build()

        let elapsed = await ContinuousClock()
            .measure {
                await #expect {
                    _ = try await client.get(url).callTimeout(.milliseconds(50)).send()
                } throws: { kind(of: $0) == .timedOut }
            }

        #expect(elapsed < .seconds(2))
    }

    @Test("CallTimeoutTests: a call that finishes within its limit succeeds")
    func testWithinLimit() async throws {
        let client = NetSkeinClient.testing().addStub(HTTPStub.get(url).text("ok")).build()

        let response = try await client.get(url).callTimeout(.seconds(5)).send()

        #expect(response.text() == "ok")
    }

    @Test(
        "CallTimeoutTests: a retry whose wait would pass the limit is skipped for the last response"
    )
    func testRetryWaitPastLimit() async throws {
        let client = NetSkeinClient.testing()
            .retryPolicy(.standard(maxRetries: 3, backoff: .immediate))
            .addStub(HTTPStub.get(url).status(.serviceUnavailable).header("Retry-After", "1"))
            .addStub(HTTPStub.get(url).text("ok"))
            .build()

        let response = try await client.get(url).callTimeout(.milliseconds(500)).send()

        #expect(response.status == .serviceUnavailable)
        #expect((client.transport as? MockHTTPClient)?.requests.count == 1)
    }

    @Test("CallTimeoutTests: cancelling the caller reports a cancellation, not a timeout")
    func testCallerCancellation() async {
        let client = NetSkeinClient.testing()
            .addStub(HTTPStub.get(url).delay(.seconds(5)).text("late"))
            .build()

        let call = Task { try await client.get(url).callTimeout(.seconds(5)).send() }
        call.cancel()

        await #expect {
            _ = try await call.value
        } throws: { kind(of: $0) == .networkFailure }
    }

    @Test("CallTimeoutTests: a timed-out call does not count against the server's circuit")
    func testCircuitBreakerIgnoresTimeouts() async {
        let breaker = CircuitBreaker.testing(clock: TestClock(), failureThreshold: 1)
        let client = NetSkeinClient.testing()
            .circuitBreaker(breaker)
            .addStub(HTTPStub.get(url).delay(.seconds(5)).text("late"))
            .build()

        await #expect {
            _ = try await client.get(url).callTimeout(.milliseconds(50)).send()
        } throws: { kind(of: $0) == .timedOut }

        #expect(breaker.state(for: "https://api.example.com") == .closed)
    }
}

// MARK: - Client Default

extension CallTimeoutTests {
    @Test("CallTimeoutTests: requests follow the client's limit unless they change or remove it")
    func testClientDefault() async throws {
        let client = NetSkeinClient.testing()
            .callTimeout(.milliseconds(50))
            .addStub(HTTPStub.get(url).delay(.milliseconds(300)).text("ok"))
            .build()

        await #expect {
            _ = try await client.get(url).send()
        } throws: { kind(of: $0) == .timedOut }

        #expect(try await client.get(url).callTimeout(nil).send().text() == "ok")
        #expect(try await client.get(url).callTimeout(.seconds(5)).send().text() == "ok")
    }

    @Test("CallTimeoutTests: the limit is kept when a body is attached")
    func testKeptWithBody() async {
        let postURL = "https://api.example.com/items"
        let client = NetSkeinClient.testing()
            .addStub(HTTPStub.post(postURL).delay(.seconds(5)).text("late"))
            .build()

        await #expect {
            _ = try await client.post(postURL)
                .callTimeout(.milliseconds(50))
                .form(["name": "value"])
                .send()
        } throws: { kind(of: $0) == .timedOut }
    }

    @Test("CallTimeoutTests: both builders pass the limit to the client")
    func testBuilders() async throws {
        let production = NetSkeinClient.builder().callTimeout(.seconds(5)).build()
        let testing = NetSkeinClient.testing().callTimeout(.seconds(5)).build()

        #expect(production.callTimeout == .seconds(5))
        #expect(testing.callTimeout == .seconds(5))
        #expect(NetSkeinClient.testing().build().callTimeout == nil)

        try await production.shutdown()
    }
}
