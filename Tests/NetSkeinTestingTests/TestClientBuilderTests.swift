import AsyncHTTPClient
import Logging
import NIOConcurrencyHelpers
import NIOHTTP1
import Testing

@testable import NetSkein
@testable import NetSkeinTesting

struct TestClientBuilderTests {
    @Test(
        "TestClientBuilderTests: Verify that static factory initializes builder cleanly with default parameters"
    )
    func staticFactoryInitializesCleanly() {
        let client = NetSkeinClient.testing().build()

        #expect(client.defaultHeaders.isEmpty)
    }

    @Test(
        "TestClientBuilderTests: Verify configuration of default headers updates correctly via builder chaining"
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
        "TestClientBuilderTests: Verify cookie store jar mapping establishes perfectly on build outcome"
    )
    func cookieJarConfigurationUpdatesValue() {
        let expectedJar = CookieJar()  // Assumes constructor availability

        let client = NetSkeinClient.testing()
            .cookieJar(expectedJar)
            .build()

        #expect(client.cookieJar === expectedJar)
    }

    @Test(
        "TestClientBuilderTests: Verify retry policy replace default policy"
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
        "TestClientBuilderTests: Verify custom logger settings replace framework operational defaults"
    )
    func loggerConfigurationUpdatesValue() {
        let customLogger = Logger(label: "com.netskein.custom.test.logger")

        let client = NetSkeinClient.testing()
            .logger(customLogger)
            .build()

        #expect(client.logger.label == "com.netskein.custom.test.logger")
    }

    @Test(
        "TestClientBuilderTests: Verify single mock stub insertion expands underlying stub configurations accurately"
    )
    func addSingleStubAppendsToCollection() async throws {
        let stub = HTTPStub(
            method: .POST,
            url: "https://example.com",
            outcome: .response(status: .ok, headers: [:], body: nil)
        )

        let client = NetSkeinClient.testing()
            .addStub(stub)
            .build()

        var request = HTTPClientRequest(url: "https://example.com")
        request.method = .POST
        let response = try await client.transport.execute(request, timeout: .seconds(1))
        #expect(response.status == .ok)
    }

    @Test(
        "TestClientBuilderTests: Verify bulk stub insertion merges sequences accurately within the registry block"
    )
    func addMultipleStubsAppendsToCollection() async throws {
        let stub1 = HTTPStub(
            method: .GET,
            urlMatcher: { $0.contains("/bulk1") },
            outcome: .response(status: .ok, headers: [:], body: nil),
        )
        let stub2 = HTTPStub(
            method: .GET,
            urlMatcher: { $0.contains("/bulk2") },
            outcome: .response(status: .accepted, headers: [:], body: nil)
        )

        let client = NetSkeinClient.testing()
            .addStubs([stub1, stub2])
            .build()

        let req1 = HTTPClientRequest(url: "https://example.com/bulk1")
        let res1 = try await client.transport.execute(req1, timeout: .seconds(1))
        #expect(res1.status == .ok)

        let req2 = HTTPClientRequest(url: "https://example.com/bulk2")
        let res2 = try await client.transport.execute(req2, timeout: .seconds(1))
        #expect(res2.status == .accepted)
    }

    @Test(
        "TestClientBuilderTests: Verify shutdown handling intercept cascades cleanly downstream to underlying mock runners"
    )
    func onShutdownPropagatesToMockClient() async throws {
        let isShutdownTriggered = NIOLockedValueBox(false)

        let client = NetSkeinClient.testing()
            .onShutdown {
                isShutdownTriggered.withLockedValue { $0 = true }
            }
            .build()

        try await client.transport.shutdown()

        let validationResult = isShutdownTriggered.withLockedValue { $0 }
        #expect(validationResult == true)
    }
}

// MARK: - Middleware Registration

extension TestClientBuilderTests {
    @Test("TestClientBuilderTests: Verify using appends type and closure middleware to the client")
    func usingAppendsMiddleware() {
        let client = NetSkeinClient.testing()
            .using(ClosureMiddleware { request, _, next in try await next(request) })
            .using { request, _, next in try await next(request) }
            .build()

        #expect(client.middlewares.count == 2)
    }
}
