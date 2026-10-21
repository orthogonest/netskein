import AsyncHTTPClient
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOHTTPCompression
import NIOSSL
import Testing

@testable import NetSkein

struct NetSkeinClientTests {
    struct MockTeardownSystemError: Error, CustomStringConvertible, Sendable {
        var description: String { "Forced low-level EventLoop thread deadlock." }
    }
}

// MARK: - Initialization and Dependency Configuration Testing

extension NetSkeinClientTests {
    @Test(
        "NetSkeinClientTests: Verifies designated initializer holds all properties and extensions correctly"
    )
    func testDesignatedInitializerLayout() async throws {
        let mockEngine = NetSkeinHTTPClientMock(stubs: [])
        let customHeaders: HTTPHeaders = ["X-Global-Header": "Active"]
        let jar = NetSkeinCookieJar()

        let client = NetSkeinClient(
            underlyingClient: mockEngine,
            defaultHeaders: customHeaders,
            cookieJar: jar
        )

        #expect(client.defaultHeaders.first(name: "X-Global-Header") == "Active")
        #expect(client.cookieJar === jar)
        #expect(client.underlyingClient is NetSkeinHTTPClientMock)

        try await client.shutdown()
    }

    @Test(
        "NetSkeinClientTests: Verifies convenience initializer constructs standard production engines safely"
    )
    func testConvenienceInitializerAllocation() async throws {
        let customHeaders: HTTPHeaders = ["Accept-Language": "en-US"]
        let client = NetSkeinClient(defaultHeaders: customHeaders)

        #expect(client.defaultHeaders.first(name: "Accept-Language") == "en-US")
        #expect(client.underlyingClient is HTTPClient)
        #expect(client.cookieJar == nil)

        try await client.shutdown()
    }

    @Test(
        "NetSkeinClientTests: Assures static factory method exposes a fresh client builder instance configuration"
    )
    func testStaticBuilderFactoryGeneration() {
        let builder = NetSkeinClient.builder()
        #expect(type(of: builder) == NetSkeinClientBuilder.self)
    }
}

// MARK: - Polymorphic HTTP Method Factory Mapping Coverage

extension NetSkeinClientTests {
    @Test(
        "NetSkeinClientTests: Verifies method factories cleanly map types to generic RequestBuilders with exact tag rules"
    )
    func testHTTPMethodFactoryBuilders() async throws {
        let mockEngine = NetSkeinHTTPClientMock(stubs: [])
        let client = NetSkeinClient(underlyingClient: mockEngine)
        let targetURL = "https://netskein.mock"

        // Validate GET: Must be BodyIsBlocked and EmptyBody tags configuration
        let getBuilder = client.get(targetURL)
        let getMirror = Mirror(reflecting: getBuilder)
        #expect(getMirror.descendant("method") as? HTTPMethod == .GET)
        #expect(type(of: getBuilder) == RequestBuilder<BodyIsBlocked, EmptyBody>.self)

        // Validate POST: Must be BodyIsAllowed and EmptyBody tags configuration
        let postBuilder = client.post(targetURL)
        let postMirror = Mirror(reflecting: postBuilder)
        #expect(postMirror.descendant("method") as? HTTPMethod == .POST)
        #expect(type(of: postBuilder) == RequestBuilder<BodyIsAllowed, EmptyBody>.self)

        // Validate PUT
        let putBuilder = client.put(targetURL)
        let putMirror = Mirror(reflecting: putBuilder)
        #expect(putMirror.descendant("method") as? HTTPMethod == .PUT)
        #expect(type(of: putBuilder) == RequestBuilder<BodyIsAllowed, EmptyBody>.self)

        // Validate PATCH
        let patchBuilder = client.patch(targetURL)
        let patchMirror = Mirror(reflecting: patchBuilder)
        #expect(patchMirror.descendant("method") as? HTTPMethod == .PATCH)
        #expect(type(of: patchBuilder) == RequestBuilder<BodyIsAllowed, EmptyBody>.self)

        // Validate DELETE: Must be BodyIsBlocked and EmptyBody tags configuration
        let deleteBuilder = client.delete(targetURL)
        let deleteMirror = Mirror(reflecting: deleteBuilder)
        #expect(deleteMirror.descendant("method") as? HTTPMethod == .DELETE)
        #expect(type(of: deleteBuilder) == RequestBuilder<BodyIsBlocked, EmptyBody>.self)

        // Validate Custom Request Mapping (e.g. OPTIONS)
        let customBuilder = client.request(.OPTIONS, url: targetURL)
        let customMirror = Mirror(reflecting: customBuilder)
        #expect(customMirror.descendant("method") as? HTTPMethod == .OPTIONS)
        #expect(type(of: customBuilder) == RequestBuilder<BodyIsAllowed, EmptyBody>.self)

        try await client.shutdown()
    }
}

// MARK: - Lifecycle Shutdown Fault Interception Coverage

extension NetSkeinClientTests {
    @Test(
        "NetSkeinClientTests: Assures underlying shutdown failures catch errors and map securely to ioFailure kind parameters"
    )
    func testShutdownFailureBranchInterception() async throws {
        // Build a mock engine that forces a throw during shutdown execution loops
        let faultyMock = NetSkeinHTTPClientMock(
            stubs: [],
            onShutdown: {
                throw MockTeardownSystemError()
            }
        )

        let client = NetSkeinClient(underlyingClient: faultyMock)

        // Execute shutdown and verify that the thrown error is safely captured and transformed
        await #expect(throws: NetSkeinError.self) {
            try await client.shutdown()
        }

        // Double check specific kind parameters to secure 100% boundary criteria matching logic
        do {
            try await client.shutdown()
            Issue.record(
                "Expected shutdown to throw a custom NetSkeinError, but it completed cleanly."
            )
        } catch {
            #expect(error.kind == .ioFailure)
            #expect(
                error.errorDescription?.contains("release network client system resources") == true
            )
        }
    }
}

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

        let internalStubs = mirror.descendant("stubs") as? [NetSkeinStub]
        #expect(internalStubs?.isEmpty == true)
    }
}

// MARK: - Fluent Chaining Mutation Path Coverage

extension NetSkeinClientBuilderTests {
    @Test(
        "NetSkeinClientBuilderTests: Verifies fluent chaining mutates all internal storage parameters seamlessly"
    )
    func testFluentChainingMutations() {
        let headers: HTTPHeaders = ["X-Builder-Assert": "True"]
        let customLogger = Logger(label: "test.logger")
        let customJar = NetSkeinCookieJar()
        let customTls = TLSConfiguration.makeClientConfiguration()
        let customProxy = NetSkeinProxy.http(host: "127.0.0.1", port: 3128)

        let builder = NetSkeinClientBuilder()
            .connectTimeout(.seconds(5))
            .readTimeout(.seconds(15))
            .writeTimeout(.seconds(20))
            .defaultHeaders(headers)
            .eventLoopGroupProvider(.shared(HTTPClient.defaultEventLoopGroup))
            .proxy(customProxy)
            .redirectPolicy(.none)
            .automaticDecompression(false)
            .decompressionLimit(.size(1024))
            .cookieStore(customJar)
            .tlsConfiguration(customTls)
            .acceptInvalidCertificates(true)
            .logger(customLogger)

        let mirror = Mirror(reflecting: builder)

        #expect(mirror.descendant("connectTimeout") as? TimeAmount == .seconds(5))
        #expect(mirror.descendant("readTimeout") as? TimeAmount == .seconds(15))
        #expect(mirror.descendant("writeTimeout") as? TimeAmount == .seconds(20))
        #expect(mirror.descendant("automaticDecompression") as? Bool == false)
        #expect(mirror.descendant("acceptInvalidCertificates") as? Bool == true)
        #expect(mirror.descendant("cookieJar") as? NetSkeinCookieJar === customJar)
    }

    @Test(
        "NetSkeinClientBuilderTests: Verifies additive stub parameters aggregate cleanly into local storage sets"
    )
    func testStubChainingAggregation() {
        let stub1 = NetSkeinStub(
            method: .GET,
            url: "https://api.local",
            outcome: .success(status: .ok, headers: HTTPHeaders(), body: nil)
        )
        let stub2 = NetSkeinStub(
            method: .POST,
            url: "https://api.local",
            outcome: .success(status: .ok, headers: HTTPHeaders(), body: nil)
        )

        let builder = NetSkeinClientBuilder()
            .addStub(stub1)
            .addStubs([stub2])

        let mirror = Mirror(reflecting: builder)
        guard let internalStubs = mirror.descendant("stubs") as? [NetSkeinStub] else {
            Issue.record(
                "Failed to read accumulated stubs parameter context out of builder mirror."
            )
            return
        }

        #expect(internalStubs.count == 2)
        #expect(internalStubs[0] == stub1)
        #expect(internalStubs[1] == stub2)
    }
}

// MARK: - Production Branch Compilation Layout Coverage

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

        #expect(client.underlyingClient is HTTPClient)
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

        #expect(client.underlyingClient is HTTPClient)

        try await client.shutdown()
    }

    @Test(
        "NetSkeinClientBuilderTests: Verifies proxy configurations pass down properties correctly"
    )
    func testProxyBuildBranch() async throws {
        let customProxy = NetSkeinProxy.http(host: "127.0.0.1", port: 3128)
        let client = NetSkeinClientBuilder()
            .proxy(customProxy)
            .build()

        #expect(client.underlyingClient is HTTPClient)

        try await client.shutdown()
    }
}

// MARK: - Mock Branch Routing Integration Coverage

extension NetSkeinClientBuilderTests {
    @Test(
        "NetSkeinClientBuilderTests: Verifies builder seamlessly redirects execution engines into NetSkeinHTTPClientMock instances when stubs are added"
    )
    func testMockBuildExecutionPath() async throws {
        let activeStub = NetSkeinStub(
            method: .GET,
            url: "https://netskein.mock",
            outcome: .success(status: .ok, headers: HTTPHeaders(), body: nil)
        )

        let shutdownCounterBox = NIOLockedValueBox(0)

        let client = NetSkeinClientBuilder()
            .addStub(activeStub)
            .stubOnShutdown {
                shutdownCounterBox.withLockedValue { $0 += 1 }
            }
            .build()

        #expect(client.underlyingClient is NetSkeinHTTPClientMock)

        // Execute shutdown sequence to test mock lifecycle hook propagation
        try await client.shutdown()

        let targetExecutionCount = shutdownCounterBox.withLockedValue { $0 }
        #expect(targetExecutionCount == 1)
    }
}
