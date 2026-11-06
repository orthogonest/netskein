import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import Testing

@testable import NetSkein
@testable import NetSkeinTesting

/// The breaker inside a client: its place next to the network, and how it works with retries,
/// the cache and cancellation.
struct CircuitBreakerClientTests {
    let url = "https://api.example.com/items"

    struct Dropped: Error {}

    func requestCount(_ client: NetSkeinClient) -> Int {
        (client.transport as? MockHTTPClient)?.requests.count ?? -1
    }

    func isCircuitOpen(_ error: any Error) -> Bool {
        (error as? NetSkeinError)?.kind == .circuitOpen
    }
}

extension CircuitBreakerClientTests {
    @Test("CircuitBreakerClientTests: an open circuit rejects requests without sending them")
    func testRejectsWithoutSending() async throws {
        let client = NetSkeinClient.testing()
            .circuitBreaker(.testing(clock: TestClock(), failureThreshold: 2))
            .addStub(HTTPStub.get(url).status(.serviceUnavailable))
            .build()

        _ = try await client.get(url).send()
        _ = try await client.get(url).send()
        await #expect {
            _ = try await client.get(url).send()
        } throws: { isCircuitOpen($0) }

        #expect(requestCount(client) == 2)
    }

    @Test("CircuitBreakerClientTests: network failures count toward opening the circuit")
    func testNetworkFailuresCount() async {
        let client = NetSkeinClient.testing()
            .circuitBreaker(.testing(clock: TestClock(), failureThreshold: 1))
            .addStub(HTTPStub.get(url).fail(with: Dropped()))
            .build()

        await #expect {
            _ = try await client.get(url).send()
        } throws: { ($0 as? NetSkeinError)?.kind == .networkFailure }
        await #expect {
            _ = try await client.get(url).send()
        } throws: { isCircuitOpen($0) }

        #expect(requestCount(client) == 1)
    }

    @Test("CircuitBreakerClientTests: retries stop as soon as the circuit opens")
    func testRetriesStop() async {
        let client = NetSkeinClient.testing()
            .retryPolicy(.standard(maxRetries: 3, backoff: .immediate))
            .circuitBreaker(.testing(clock: TestClock(), failureThreshold: 2))
            .addStub(HTTPStub.get(url).status(.serviceUnavailable))
            .build()

        await #expect {
            _ = try await client.get(url).send()
        } throws: { isCircuitOpen($0) }

        #expect(requestCount(client) == 2)
    }

    @Test("CircuitBreakerClientTests: the cache can stand in while the circuit is open")
    func testCacheStandsIn() async throws {
        let clock = TestClock()
        let client = NetSkeinClient.testing()
            .cache(.testing(clock: clock, maxStaleOnError: .seconds(60)))
            .circuitBreaker(.testing(clock: clock, failureThreshold: 1))
            .addStub(HTTPStub.get(url).header("Cache-Control", "max-age=1").text("cached"))
            .addStub(HTTPStub.get(url).status(.serviceUnavailable))
            .build()

        _ = try await client.get(url).send()
        clock.advance(by: .seconds(2))

        // The 503 opens the circuit; the stale response stands in for it, then for the
        // rejected request
        let afterFailure = try await client.get(url).send()
        let whileOpen = try await client.get(url).send()

        #expect(afterFailure.text() == "cached")
        #expect(whileOpen.text() == "cached")
        #expect(requestCount(client) == 2)
    }

    @Test("CircuitBreakerClientTests: a cancelled trial does not count, so another can follow")
    func testCancelledTrial() async throws {
        let clock = TestClock()
        let breaker = CircuitBreaker.testing(clock: clock, failureThreshold: 1)
        let client = NetSkeinClient.testing()
            .circuitBreaker(breaker)
            .addStub(HTTPStub.get(url).status(.serviceUnavailable))
            .addStub(HTTPStub.get(url).delay(.milliseconds(1)).text("ok"))
            .build()

        _ = try await client.get(url).send()
        clock.advance(by: .seconds(30))

        // Cancelled after the breaker let the trial through, while it waits for the transport;
        // in its own task, since cancelling cancels the task it runs in
        let cancelled = Task {
            try await client.get(url)
                .using { request, _, next in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try await next(request)
                }
                .send()
        }
        await #expect(throws: NetSkeinError.self) { _ = try await cancelled.value }
        #expect(breaker.state(for: "https://api.example.com") == .halfOpen)

        let response = try await client.get(url).send()
        #expect(response.text() == "ok")
        #expect(breaker.state(for: "https://api.example.com") == .closed)
    }
}

// MARK: - Registration

extension CircuitBreakerClientTests {
    @Test("CircuitBreakerClientTests: both builders pass the breaker to the client")
    func testBuilders() async throws {
        let breaker = CircuitBreaker()

        let production = NetSkeinClient.builder().circuitBreaker(breaker).build()
        let testing = NetSkeinClient.testing().circuitBreaker(breaker).build()

        #expect(production.circuitBreaker === breaker)
        #expect(testing.circuitBreaker === breaker)
        #expect(NetSkeinClient.testing().build().circuitBreaker == nil)

        try await production.shutdown()
    }
}
