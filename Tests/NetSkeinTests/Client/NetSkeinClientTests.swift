import Logging
import NIOHTTP1
import Testing

@testable import NetSkein
@testable import NetSkeinTesting

struct NetSkeinClientTests {
    struct MockTeardownSystemError: Error, CustomStringConvertible, Sendable {
        var description: String { "Forced low-level EventLoop thread deadlock." }
    }
}

// MARK: - Initialization and Dependency Configuration

extension NetSkeinClientTests {
    @Test(
        "NetSkeinClientTests: Verifies designated initializer holds all properties and extensions correctly"
    )
    func testDesignatedInitializerLayout() async throws {
        let mockTransport = MockHTTPClient(stubs: [])
        let customHeaders: HTTPHeaders = ["X-Global-Header": "Active"]
        let jar = CookieJar()

        let client = NetSkeinClient(
            transport: mockTransport,
            defaultHeaders: customHeaders,
            cookieJar: jar,
            logger: Logger(label: LoggerLabel.test)
        )

        #expect(client.defaultHeaders.first(name: "X-Global-Header") == "Active")
        #expect(client.cookieJar === jar)

        try await client.shutdown()
    }

    @Test(
        "NetSkeinClientTests: Verifies convenience initializer constructs standard production engines safely"
    )
    func testConvenienceInitializerAllocation() async throws {
        let customHeaders: HTTPHeaders = ["Accept-Language": "en-US"]
        let client = NetSkeinClient(defaultHeaders: customHeaders)

        #expect(client.defaultHeaders.first(name: "Accept-Language") == "en-US")
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

// MARK: - Polymorphic HTTP Method Factory

extension NetSkeinClientTests {
    @Test(
        "NetSkeinClientTests: Verifies method factories cleanly map types to generic NetSkeinRequest with exact tag rules"
    )
    func testHTTPMethodFactoryBuilders() async throws {
        let mockEngine = MockHTTPClient(stubs: [])
        let client = NetSkeinClient(transport: mockEngine, logger: Logger(label: LoggerLabel.test))
        let targetURL = "https://netskein.mock"

        // Validate GET: Must be BodyForbidden tags configuration
        let getBuilder = client.get(targetURL)
        let getMirror = Mirror(reflecting: getBuilder)
        #expect(getMirror.descendant("method") as? HTTPMethod == .GET)
        #expect(
            type(of: getBuilder) == NetSkeinRequest<MockHTTPClient, BodyForbidden>.self
        )

        // Validate POST: Must be BodyAllowed tags configuration
        let postBuilder = client.post(targetURL)
        let postMirror = Mirror(reflecting: postBuilder)
        #expect(postMirror.descendant("method") as? HTTPMethod == .POST)
        #expect(
            type(of: postBuilder) == NetSkeinRequest<MockHTTPClient, BodyAllowed>.self
        )

        // Validate PU: Must be BodyAllowed tags configurationT
        let putBuilder = client.put(targetURL)
        let putMirror = Mirror(reflecting: putBuilder)
        #expect(putMirror.descendant("method") as? HTTPMethod == .PUT)
        #expect(
            type(of: putBuilder) == NetSkeinRequest<MockHTTPClient, BodyAllowed>.self
        )

        // Validate PATC: Must be BodyAllowed tags configurationH
        let patchBuilder = client.patch(targetURL)
        let patchMirror = Mirror(reflecting: patchBuilder)
        #expect(patchMirror.descendant("method") as? HTTPMethod == .PATCH)
        #expect(
            type(of: patchBuilder) == NetSkeinRequest<MockHTTPClient, BodyAllowed>.self
        )

        // Validate DELETE: Must be BodyForbidden tags configuration
        let deleteBuilder = client.delete(targetURL)
        let deleteMirror = Mirror(reflecting: deleteBuilder)
        #expect(deleteMirror.descendant("method") as? HTTPMethod == .DELETE)
        #expect(
            type(of: deleteBuilder)
                == NetSkeinRequest<MockHTTPClient, BodyForbidden>.self
        )

        // Validate Custom Request Mapping (e.g. OPTIONS)
        let customBuilder = client.request(.OPTIONS, url: targetURL)
        let customMirror = Mirror(reflecting: customBuilder)
        #expect(customMirror.descendant("method") as? HTTPMethod == .OPTIONS)
        #expect(
            type(of: customBuilder) == NetSkeinRequest<MockHTTPClient, BodyAllowed>.self
        )

        try await client.shutdown()
    }
}

// MARK: - Lifecycle Shutdown Fault Interception

extension NetSkeinClientTests {
    @Test(
        "NetSkeinClientTests: Assures underlying shutdown failures catch errors and map securely to ioFailure kind parameters"
    )
    func testShutdownFailureBranchInterception() async throws {
        // Build a mock engine that forces a throw during shutdown execution loops
        let faultyMock = MockHTTPClient(
            stubs: [],
            onShutdown: {
                throw MockTeardownSystemError()
            }
        )

        let client = NetSkeinClient(transport: faultyMock, logger: Logger(label: LoggerLabel.test))

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
