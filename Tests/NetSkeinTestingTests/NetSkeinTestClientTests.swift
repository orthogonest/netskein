import AsyncHTTPClient
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import Testing

@testable import NetSkein
@testable import NetSkeinTesting

struct MockHTTPClientTests {
    @Test(
        "MockHTTPClientTests: Verify that the first matching stub returns success on the first execution"
    )
    func executeReturnsSuccessOnFirstMatch() async throws {
        let expectedBuffer = ByteBuffer(string: "Hello World")
        let stub = NetSkeinStub(
            method: .GET,
            urlMatcher: { $0 == "https://example.com" },
            outcome: .success(status: .ok, headers: [:], body: expectedBuffer)
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
        let stub1 = NetSkeinStub(
            method: .GET,
            urlMatcher: { _ in true },
            outcome: .success(status: .ok, headers: [:], body: nil)
        )
        let stub2 = NetSkeinStub(
            method: .GET,
            urlMatcher: { _ in true },
            outcome: .success(status: .accepted, headers: [:], body: nil)
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
        let stub = NetSkeinStub(
            method: .GET,
            urlMatcher: { _ in true },
            outcome: .success(status: .created, headers: [:], body: nil)
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

        let stub = NetSkeinStub(
            method: .GET,
            urlMatcher: { _ in true },
            requestValidator: { _ in
                throw DummyValidationError()
            },
            outcome: .success(status: .ok, headers: [:], body: nil),
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
        let stub = NetSkeinStub(
            method: .GET,
            urlMatcher: { _ in true },
            delay: .milliseconds(100),
            requestValidator: nil,
            outcome: .success(status: .ok, headers: [:], body: nil)
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

        let stub = NetSkeinStub(
            method: .GET,
            urlMatcher: { _ in true },
            outcome: .failure(MockNetworkError())
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

struct NetSkeinTestClientBuilderTests {
    @Test(
        "NetSkeinTestClientBuilderTests: Verify that static factory initializes builder cleanly with default parameters"
    )
    func staticFactoryInitializesCleanly() {
        let client = NetSkeinClient.testing().build()

        #expect(client.defaultHeaders.isEmpty)
    }

    @Test(
        "NetSkeinTestClientBuilderTests: Verify configuration of default headers updates correctly via builder chaining"
    )
    func defaultHeadersConfigurationUpdatesValue() {
        var headers = HTTPHeaders()
        headers.add(name: "X-Test-Header", value: "BuilderValue")

        let client = NetSkeinClient.testing()
            .defaultHeaders(headers)
            .build()

        #expect(client.defaultHeaders.contains(name: "X-Test-Header"))
        #expect(client.defaultHeaders.first(name: "X-Test-Header") == "BuilderValue")
    }

    @Test(
        "NetSkeinTestClientBuilderTests: Verify cookie store jar mapping establishes perfectly on build outcome"
    )
    func cookieStoreConfigurationUpdatesValue() {
        let expectedJar = NetSkeinCookieJar()  // Assumes constructor availability

        let client = NetSkeinClient.testing()
            .cookieStore(expectedJar)
            .build()

        #expect(client.cookieJar === expectedJar)
    }

    @Test(
        "NetSkeinTestClientBuilderTests: Verify retry policy replace default policy"
    )
    func retryPolicyConfigurationUpdatesValue() {
        let policy = RetryPolicy.standard(maxRetries: 5)

        let client = NetSkeinClient.testing()
            .retryPolicy(policy)
            .build()

        #expect(client.retryPolicy.maxRetries == policy.maxRetries)
        #expect(client.retryPolicy.respectRetryAfterHeader == policy.respectRetryAfterHeader)
    }

    @Test(
        "NetSkeinTestClientBuilderTests: Verify custom logger settings replace framework operational defaults"
    )
    func loggerConfigurationUpdatesValue() {
        let customLogger = Logger(label: "com.netskein.custom.test.logger")

        let client = NetSkeinClient.testing()
            .logger(customLogger)
            .build()

        #expect(client.logger.label == "com.netskein.custom.test.logger")
    }

    @Test(
        "NetSkeinTestClientBuilderTests: Verify single mock stub insertion expands underlying stub configurations accurately"
    )
    func addSingleStubAppendsToCollection() async throws {
        let stub = NetSkeinStub(
            method: .POST,
            url: "https://example.com",
            outcome: .success(status: .ok, headers: [:], body: nil)
        )

        let client = NetSkeinClient.testing()
            .addStub(stub)
            .build()

        var request = HTTPClientRequest(url: "https://example.com")
        request.method = .POST
        let response = try await client.underlyingClient.execute(request, timeout: .seconds(1))
        #expect(response.status == .ok)
    }

    @Test(
        "NetSkeinTestClientBuilderTests: Verify bulk stub insertion merges sequences accurately within the registry block"
    )
    func addMultipleStubsAppendsToCollection() async throws {
        let stub1 = NetSkeinStub(
            method: .GET,
            urlMatcher: { $0.contains("/bulk1") },
            outcome: .success(status: .ok, headers: [:], body: nil),
        )
        let stub2 = NetSkeinStub(
            method: .GET,
            urlMatcher: { $0.contains("/bulk2") },
            outcome: .success(status: .accepted, headers: [:], body: nil)
        )

        let client = NetSkeinClient.testing()
            .addStubs([stub1, stub2])
            .build()

        let req1 = HTTPClientRequest(url: "https://example.com/bulk1")
        let res1 = try await client.underlyingClient.execute(req1, timeout: .seconds(1))
        #expect(res1.status == .ok)

        let req2 = HTTPClientRequest(url: "https://example.com/bulk2")
        let res2 = try await client.underlyingClient.execute(req2, timeout: .seconds(1))
        #expect(res2.status == .accepted)
    }

    @Test(
        "NetSkeinTestClientBuilderTests: Verify shutdown handling intercept cascades cleanly downstream to underlying mock runners"
    )
    func stubOnShutdownPropagatesToMockClient() async throws {
        let isShutdownTriggered = NIOLockedValueBox(false)

        let client = NetSkeinClient.testing()
            .stubOnShutdown {
                isShutdownTriggered.withLockedValue { $0 = true }
            }
            .build()

        try await client.underlyingClient.shutdown()

        let validationResult = isShutdownTriggered.withLockedValue { $0 }
        #expect(validationResult == true)
    }
}
