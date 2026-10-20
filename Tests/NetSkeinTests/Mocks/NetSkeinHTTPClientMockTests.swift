import AsyncHTTPClient
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import Testing

@testable import NetSkein

struct NetSkeinHTTPClientMockTests {
    struct MockNetworkFailureError: Error, CustomStringConvertible, Sendable {
        var description: String { "Simulated system socket outage." }
    }
}

// MARK: - Route Matching and Sequential Fallback Paths

extension NetSkeinHTTPClientMockTests {
    @Test(
        "NetSkeinHTTPClientMockTests: Verifies standard successful execute maps correct response heads and buffers"
    )
    func testExecuteSuccessPath() async throws {
        let expectedBuffer = ByteBuffer(string: "mock_data")
        let stub = NetSkeinStub(
            method: .GET,
            url: "https://netskein.mock",
            outcome: .success(
                status: .ok,
                headers: ["Content-Type": "text/plain"],
                body: expectedBuffer
            )
        )

        let mockClient = NetSkeinHTTPClientMock(stubs: [stub])
        let request = HTTPClientRequest(url: "https://netskein.mock")  // Default method is GET

        let response = try await mockClient.execute(request, timeout: .seconds(5))

        #expect(response.status == .ok)
        #expect(response.headers.first(name: "Content-Type") == "text/plain")

        // Collect bytes out of the standard async response body sequence cleanly
        var collectedBody = try await response.body.collect(upTo: 1024)
        let bodyString = collectedBody.readString(length: collectedBody.readableBytes)
        #expect(bodyString == "mock_data")

        try await mockClient.shutdown()
    }

    @Test(
        "NetSkeinHTTPClientMockTests: Ensures multiple identical route calls rotate through sequential stubs and fall back to the last match if index bounds are exceeded"
    )
    func testSequentialStubResolutionAndLastMatchFallback() async throws {
        // Register two distinct response states on the exact same endpoint route string
        let stubFirstCall = NetSkeinStub(
            method: .GET,
            url: "https://netskein.mock",
            outcome: .success(
                status: .ok,
                headers: HTTPHeaders(),
                body: ByteBuffer(string: "STATE_1")
            )
        )
        let stubSecondCall = NetSkeinStub(
            method: .GET,
            url: "https://netskein.mock",
            outcome: .success(
                status: .ok,
                headers: HTTPHeaders(),
                body: ByteBuffer(string: "STATE_2")
            )
        )

        let mockClient = NetSkeinHTTPClientMock(stubs: [stubFirstCall, stubSecondCall])
        let request = HTTPClientRequest(url: "https://netskein.mock")

        // First Call: Resolves into safe index position 0
        let response1 = try await mockClient.execute(request, timeout: .seconds(5))
        var body1 = try await response1.body.collect(upTo: 100)
        #expect(body1.readString(length: body1.readableBytes) == "STATE_1")

        // Second Call: Resolves into safe index position 1
        let response2 = try await mockClient.execute(request, timeout: .seconds(5))
        var body2 = try await response2.body.collect(upTo: 100)
        #expect(body2.readString(length: body2.readableBytes) == "STATE_2")

        // Third Call: Exceeds indices bounds array capacity (safeIndex = 2), must fallback to return the last match ("STATE_2")
        let response3 = try await mockClient.execute(request, timeout: .seconds(5))
        var body3 = try await response3.body.collect(upTo: 100)
        #expect(body3.readString(length: body3.readableBytes) == "STATE_2")

        try await mockClient.shutdown()
    }

    @Test(
        "NetSkeinHTTPClientMockTests: Assures an unhandled route configuration triggers an immediate networkFailure guard throw"
    )
    func testUnhandledRouteThrowsNetworkFailure() async throws {
        // Empty stubs dictionary guarantees fallback path
        let mockClient = NetSkeinHTTPClientMock(stubs: [])
        let request = HTTPClientRequest(url: "https://netskein.mock")

        await #expect(throws: NetSkeinError.self) {
            try await mockClient.execute(request, timeout: .seconds(5))
        }

        try await mockClient.shutdown()
    }
}

// MARK: - Validation Blocks, Failure Outcomes, and Latency Coverage

extension NetSkeinHTTPClientMockTests {
    @Test(
        "NetSkeinHTTPClientMockTests: Verifies requestValidator intercept block fires successfully and catches failure assertions"
    )
    func testRequestValidatorHookFires() async throws {
        let stub = NetSkeinStub(
            method: .POST,
            url: "https://netskein.mock",
            requestValidator: { @Sendable request in
                guard request.headers.contains(name: "X-Required-Token") else {
                    throw NetSkeinError.custom(
                        kind: .clientError,
                        message: "Missing Token Constraint"
                    )
                }
            },
            outcome: .success(status: .ok, headers: HTTPHeaders())
        )

        let mockClient = NetSkeinHTTPClientMock(stubs: [stub])

        // Scenario A: Missing header criteria forces validator crash throwing conversion loop
        var requestInvalid = HTTPClientRequest(url: "https://netskein.mock")
        requestInvalid.method = .POST
        await #expect(throws: NetSkeinError.self) {
            try await mockClient.execute(requestInvalid, timeout: .seconds(5))
        }

        // Scenario B: Passing valid configuration bypasses rules safely
        var requestValid = HTTPClientRequest(url: "https://netskein.mock")
        requestValid.method = .POST
        requestValid.headers.add(name: "X-Required-Token", value: "secure_payload")
        let response = try await mockClient.execute(requestValid, timeout: .seconds(5))
        #expect(response.status == .ok)

        try await mockClient.shutdown()
    }

    @Test(
        "NetSkeinHTTPClientMockTests: Verifies artificial latency delay blocks execution loops accurately"
    )
    func testArtificialDelayExecutionPath() async throws {
        let stub = NetSkeinStub(
            method: .GET,
            url: "https://netskein.mock",
            delay: .milliseconds(10),  // Injected structural delay block
            outcome: .success(status: .ok, headers: HTTPHeaders())
        )

        let mockClient = NetSkeinHTTPClientMock(stubs: [stub])
        let request = HTTPClientRequest(url: "https://netskein.mock")

        let startTime = DispatchTime.now()
        let response = try await mockClient.execute(request, timeout: .seconds(5))
        let endTime = DispatchTime.now()

        let durationNanoseconds = endTime.uptimeNanoseconds - startTime.uptimeNanoseconds
        #expect(response.status == .ok)
        // Verify that execution slept and took at least 10 milliseconds (10,000,000 nanoseconds)
        #expect(durationNanoseconds >= 10_000_000)

        try await mockClient.shutdown()
    }

    @Test(
        "NetSkeinHTTPClientMockTests: Ensures failure outcomes cleanly throw designated error types bypass successfully"
    )
    func testExecuteFailurePathThrows() async throws {
        let stub = NetSkeinStub(
            method: .GET,
            url: "https://netskein.mock",
            outcome: .failure(MockNetworkFailureError())
        )

        let mockClient = NetSkeinHTTPClientMock(stubs: [stub])
        let request = HTTPClientRequest(url: "https://netskein.mock")

        await #expect(throws: MockNetworkFailureError.self) {
            try await mockClient.execute(request, timeout: .seconds(5))
        }

        try await mockClient.shutdown()
    }
}

// MARK: - Lifecycle Shutdown Hook Coverage

extension NetSkeinHTTPClientMockTests {
    @Test(
        "NetSkeinHTTPClientMockTests: Verifies shutdown lifecycle hook maps custom closures or side effects perfectly"
    )
    func testShutdownLifecycleSpyHook() async throws {
        let wasShutdownCalledBox = NIOLockedValueBox(false)

        let mockClient = NetSkeinHTTPClientMock(
            stubs: [],
            onShutdown: {
                wasShutdownCalledBox.withLockedValue { $0 = true }
            }
        )

        // Execute the cleanup teardown sequence
        try await mockClient.shutdown()

        let targetState = wasShutdownCalledBox.withLockedValue { $0 }
        #expect(targetState == true)

        try await mockClient.shutdown()
    }
}
