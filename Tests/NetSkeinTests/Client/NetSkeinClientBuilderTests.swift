import AsyncHTTPClient
import InMemoryTracing
import Logging
import NIOCore
import NIOHTTP1
import NIOSSL
import Testing
import Tracing

@testable import NetSkein

// MARK: - Baseline Builder Constructor Defaults Verification

struct NetSkeinClientBuilderTests {
    @Test(
        "NetSkeinClientBuilderTests: Verifies builder initializer falls back cleanly to the framework absolute defaults"
    )
    func testBuilderInitializerDefaults() {
        let builder = NetSkeinClientBuilder()
        let mirror = Mirror(reflecting: builder)

        #expect(mirror.descendant("connectTimeout") as? TimeAmount == .seconds(10))
        #expect(mirror.descendant("readTimeout") as? TimeAmount == .seconds(30))
        #expect(mirror.descendant("writeTimeout") as? TimeAmount == .seconds(30))
        #expect(mirror.descendant("automaticDecompression") as? Bool == true)
        #expect(mirror.descendant("acceptInvalidCertificates") as? Bool == false)
    }
}

// MARK: - Fluent Chaining

extension NetSkeinClientBuilderTests {
    @Test(
        "NetSkeinClientBuilderTests: Verifies fluent chaining mutates all internal storage parameters seamlessly"
    )
    func testFluentChainingMutations() {
        let headers: HTTPHeaders = ["X-Builder-Assert": "True"]
        let customLogger = Logger(label: "test.logger")
        let customJar = CookieJar()
        let retryPolicy = RetryPolicy.standard()
        let customTls = TLSConfiguration.makeClientConfiguration()
        let customProxy = Proxy.http(host: "127.0.0.1", port: 3128)

        let builder = NetSkeinClientBuilder()
            .connectTimeout(.seconds(5))
            .readTimeout(.seconds(15))
            .writeTimeout(.seconds(20))
            .defaultHeaders(headers)
            .eventLoopGroupProvider(.shared(HTTPClient.defaultEventLoopGroup))
            .proxy(customProxy)
            .redirectPolicy(.disabled)
            .automaticDecompression(false)
            .decompressionLimit(.size(1024))
            .cookieJar(customJar)
            .retryPolicy(retryPolicy)
            .tlsConfiguration(customTls)
            .acceptInvalidCertificates(true)
            .logger(customLogger)

        let mirror = Mirror(reflecting: builder)

        #expect(mirror.descendant("connectTimeout") as? TimeAmount == .seconds(5))
        #expect(mirror.descendant("readTimeout") as? TimeAmount == .seconds(15))
        #expect(mirror.descendant("writeTimeout") as? TimeAmount == .seconds(20))
        #expect(mirror.descendant("automaticDecompression") as? Bool == false)
        #expect(mirror.descendant("acceptInvalidCertificates") as? Bool == true)
        #expect(mirror.descendant("cookieJar") as? CookieJar === customJar)
    }
}

// MARK: - Production Branch Compilation

extension NetSkeinClientBuilderTests {
    @Test(
        "NetSkeinClientBuilderTests: Verifies build resolves into concrete standard production HTTPClient instances when no stubs are present"
    )
    func testProductionBuildExecutionPath() async throws {
        let customHeaders: HTTPHeaders = ["X-Prod-Env": "Active"]
        let client = NetSkeinClientBuilder()
            .defaultHeaders(customHeaders)
            .automaticDecompression(true)
            .acceptInvalidCertificates(true)  // Triggers .certificateVerification = .none
            .build()

        #expect(client.defaultHeaders.first(name: "X-Prod-Env") == "Active")

        // Mandatory cleanup loop to secure AsyncHTTPClient tear-down rules
        try await client.shutdown()
    }

    @Test(
        "NetSkeinClientBuilderTests: Verifies disabled decompression configurations pass down properties correctly"
    )
    func testDisabledDecompressionBuildBranch() async throws {
        let client = NetSkeinClientBuilder()
            .automaticDecompression(false)  // Triggers config.decompression = .disabled
            .build()

        #expect(client.defaultHeaders.isEmpty)

        try await client.shutdown()
    }

    @Test(
        "NetSkeinClientBuilderTests: Verifies proxy configurations pass down properties correctly"
    )
    func testProxyBuildBranch() async throws {
        let customProxy = Proxy.http(host: "127.0.0.1", port: 3128)
        let client = NetSkeinClientBuilder()
            .proxy(customProxy)
            .build()

        #expect(client.defaultHeaders.isEmpty)

        try await client.shutdown()
    }
}

// MARK: - Middleware Registration

extension NetSkeinClientBuilderTests {
    @Test("NetSkeinClientBuilderTests: Verifies using appends type and closure middleware in order")
    func testUsingAppendsMiddleware() async throws {
        let client = NetSkeinClient.builder()
            .using(PassThroughMiddleware())
            .using { request, _, next in try await next(request) }
            .build()

        #expect(client.middlewares.count == 2)
        #expect(client.middlewares.first is PassThroughMiddleware)
        #expect(client.middlewares.last is ClosureMiddleware)

        try await client.shutdown()
    }
}

// MARK: - Tracing

extension NetSkeinClientBuilderTests {
    @Test("NetSkeinClientBuilderTests: Verifies the client uses the global tracer by default")
    func testTracerDefaultsToGlobal() async throws {
        let client = NetSkeinClient.builder().build()
        let transport = try #require(client.transport as? HTTPClient)

        #expect(transport.tracer is NoOpTracer)
        #expect(client.tracer is NoOpTracer)

        try await client.shutdown()
    }

    @Test("NetSkeinClientBuilderTests: Verifies a custom tracer is passed to the transport")
    func testCustomTracer() async throws {
        let client = NetSkeinClient.builder().tracer(InMemoryTracer()).build()
        let transport = try #require(client.transport as? HTTPClient)

        #expect(transport.tracer is InMemoryTracer)
        #expect(client.tracer is InMemoryTracer)

        try await client.shutdown()
    }

    @Test("NetSkeinClientBuilderTests: Verifies disabling tracing removes the tracer")
    func testDisableTracing() async throws {
        let client = NetSkeinClient.builder().disableTracing().build()
        let transport = try #require(client.transport as? HTTPClient)

        #expect(transport.tracer == nil)
        #expect(client.tracer == nil)

        try await client.shutdown()
    }

    @Test("NetSkeinClientBuilderTests: Verifies the last tracing call wins")
    func testLastTracingCallWins() async throws {
        let traced = NetSkeinClient.builder().disableTracing().tracer(InMemoryTracer()).build()
        let untraced = NetSkeinClient.builder().tracer(InMemoryTracer()).disableTracing().build()
        let tracedTransport = try #require(traced.transport as? HTTPClient)
        let untracedTransport = try #require(untraced.transport as? HTTPClient)

        #expect(tracedTransport.tracer is InMemoryTracer)
        #expect(untracedTransport.tracer == nil)

        try await traced.shutdown()
        try await untraced.shutdown()
    }
}

private struct PassThroughMiddleware: HTTPMiddleware {
    func intercept(
        _ request: RequestHead,
        context: MiddlewareContext,
        next: Next
    ) async throws -> HTTPClientResponse {
        try await next(request)
    }
}
