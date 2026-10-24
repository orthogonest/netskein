import AsyncHTTPClient
import NIOConcurrencyHelpers
import NIOCore
import Testing

@testable import NetSkein
@testable import NetSkeinTesting

struct MockHTTPClientTests {
    @Test(
        "MockHTTPClientTests: Verify that the first matching stub returns success on the first execution"
    )
    func executeReturnsSuccessOnFirstMatch() async throws {
        let expectedBuffer = ByteBuffer(string: "Hello World")
        let stub = HTTPStub(
            method: .GET,
            urlMatcher: { $0 == "https://example.com" },
            outcome: .response(status: .ok, headers: [:], body: expectedBuffer)
        )

        let client = MockHTTPClient(stubs: [stub])
        let request = HTTPClientRequest(url: "https://example.com")

        let response = try await client.execute(request, timeout: .seconds(1))

        #expect(response.status == .ok)
    }

    @Test("MockHTTPClientTests: Verify that an unhandled route throws a NetSkeinError.custom error")
    func executeThrowsUnhandledRequestWhenNoMatchFound() async {
        let client = MockHTTPClient(stubs: [])
        let request = HTTPClientRequest(url: "https://example.com")

        await #expect(throws: NetSkeinError.self) {
            _ = try await client.execute(request, timeout: .seconds(1))
        }
    }

    @Test(
        "MockHTTPClientTests: Verify sequential matching loops properly through available stubs across multiple calls"
    )
    func executeUsesSequentialStubOnMultipleCalls() async throws {
        let stub1 = HTTPStub(
            method: .GET,
            urlMatcher: { _ in true },
            outcome: .response(status: .ok, headers: [:], body: nil)
        )
        let stub2 = HTTPStub(
            method: .GET,
            urlMatcher: { _ in true },
            outcome: .response(status: .accepted, headers: [:], body: nil)
        )

        let client = MockHTTPClient(stubs: [stub1, stub2])
        let request = HTTPClientRequest(url: "https://example.com")

        let res1 = try await client.execute(request, timeout: .seconds(1))
        #expect(res1.status == .ok)

        let res2 = try await client.execute(request, timeout: .seconds(1))
        #expect(res2.status == .accepted)
    }

    @Test(
        "MockHTTPClientTests: Verify fallback mechanism targets the last matching stub when calls exceed stub capacity"
    )
    func executeFallsBackToLastMatchWhenCallCountExceedsStubs() async throws {
        let stub = HTTPStub(
            method: .GET,
            urlMatcher: { _ in true },
            outcome: .response(status: .created, headers: [:], body: nil)
        )

        let client = MockHTTPClient(stubs: [stub])
        let request = HTTPClientRequest(url: "https://example.com")

        let res1 = try await client.execute(request, timeout: .seconds(1))
        #expect(res1.status == .created)

        let res2 = try await client.execute(request, timeout: .seconds(1))
        #expect(res2.status == .created)
    }

    @Test(
        "MockHTTPClientTests: Verify requestValidator propagates designated verification errors upon execution failure"
    )
    func executeTriggersRequestValidatorAndPropagatesError() async {
        struct DummyValidationError: Error {}

        let stub = HTTPStub(
            method: .GET,
            urlMatcher: { _ in true },
            requestValidator: { _ in
                throw DummyValidationError()
            },
            outcome: .response(status: .ok, headers: [:], body: nil),
        )

        let client = MockHTTPClient(stubs: [stub])
        let request = HTTPClientRequest(url: "https://example.com")

        await #expect(throws: DummyValidationError.self) {
            _ = try await client.execute(request, timeout: .seconds(1))
        }
    }

    @Test(
        "MockHTTPClientTests: Verify that delay constraints are applied correctly to the async execution lifecycle"
    )
    func executeAppliesDelayWhenSpecified() async throws {
        let stub = HTTPStub(
            method: .GET,
            urlMatcher: { _ in true },
            delay: .milliseconds(100),
            requestValidator: nil,
            outcome: .response(status: .ok, headers: [:], body: nil)
        )

        let client = MockHTTPClient(stubs: [stub])
        let request = HTTPClientRequest(url: "https://example.com")

        let clock = ContinuousClock()
        let duration = try await clock.measure {
            _ = try await client.execute(request, timeout: .seconds(1))
        }

        #expect(duration >= .milliseconds(100))
    }

    @Test(
        "MockHTTPClientTests: Verify that custom defined mock environment errors throw accurately when executing failure outcome"
    )
    func executeThrowsErrorWhenOutcomeIsFailure() async {
        struct MockNetworkError: Error, Equatable {}

        let stub = HTTPStub(
            method: .GET,
            urlMatcher: { _ in true },
            outcome: .error(MockNetworkError())
        )

        let client = MockHTTPClient(stubs: [stub])
        let request = HTTPClientRequest(url: "https://example.com")

        await #expect(throws: MockNetworkError.self) {
            _ = try await client.execute(request, timeout: .seconds(1))
        }
    }

    @Test(
        "MockHTTPClientTests: Verify that the designated closure evaluates seamlessly during the lifecycle shutdown process"
    )
    func shutdownExecutesOnShutdownClosure() async throws {
        let isShutdownCalled = NIOLockedValueBox(false)

        let client = MockHTTPClient(stubs: []) {
            isShutdownCalled.withLockedValue { $0 = true }
        }

        let checkBefore = isShutdownCalled.withLockedValue { $0 }
        #expect(checkBefore == false)

        try await client.shutdown()

        let checkAfter = isShutdownCalled.withLockedValue { $0 }
        #expect(checkAfter == true)
    }

    @Test(
        "MockHTTPClientTests: Verify that standard completion pathways execute seamlessly even if onShutdown defaults to nil"
    )
    func shutdownDoesNotThrowWhenOnShutdownIsNil() async throws {
        let client = MockHTTPClient(stubs: [])

        try await client.shutdown()
        #expect(true)  // Confirms control flow transitions perfectly without crashing
    }
}
