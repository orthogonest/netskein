import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import Testing

@testable import NetSkein

@Suite("NetSkeinStub Structural Analysis")
struct NetSkeinStubTests {
    struct MockStubOutageError: Error, CustomStringConvertible, Sendable {
        var description: String { "Simulated physical socket dropout error." }
    }

    @Test(
        "NetSkeinStubTests: Verifies static URL initializer locks precise string matches accurately"
    )
    func testStaticURLInitializer() {
        let stub = NetSkeinStub(
            method: .GET,
            url: "https://netskein.mock",
            delay: .seconds(2),
            requestValidator: { _ in },
            outcome: .success(status: .ok, headers: HTTPHeaders(), body: nil)
        )

        #expect(stub.method == .GET)
        #expect(stub.delay == .seconds(2))
        #expect(stub.requestValidator != nil)

        // Assert closure behavior for the exact URL matching rule
        #expect(stub.urlMatcher("https://netskein.mock") == true)
        #expect(stub.urlMatcher("https://netskein.mock1") == false)
    }

    @Test(
        "NetSkeinStubTests: Verifies closure-based urlMatcher initialization captures custom dynamic prefix pattern constraints"
    )
    func testDynamicURLMatcherInitializer() {
        let stub = NetSkeinStub(
            method: .POST,
            urlMatcher: { @Sendable url in url.hasPrefix("https://netskein.mock") },
            delay: nil,
            requestValidator: nil,
            outcome: .failure(MockStubOutageError())
        )

        #expect(stub.method == .POST)
        #expect(stub.delay == nil)
        #expect(stub.requestValidator == nil)

        // Validate regex/closure execution path bounds
        #expect(stub.urlMatcher("https://netskein.mock42") == true)
        #expect(stub.urlMatcher("https://netskeins.mock") == false)
    }

    @Test(
        "NetSkeinStubTests: Assures structural equatable operator resolves equality based on method types, delay, and outcome variants description tracking"
    )
    func testStubEquatableLogic() {
        let headersA = HTTPHeaders([("Content-Type", "application/json")])
        let headersB = HTTPHeaders([("Content-Type", "application/json")])
        let mockBody = ByteBuffer(string: "payload")

        // Baseline Stub configuration (delay: nil)
        let stub1 = NetSkeinStub(
            method: .GET,
            url: "https://netskein.mock",
            delay: nil,
            outcome: .success(status: .ok, headers: headersA, body: mockBody)
        )

        // Twin Stub layout with identical fields to verify matching parameters behavior
        let stub2 = NetSkeinStub(
            method: .GET,
            url: "https://netskein.mock-different-ignored-url",
            delay: nil,
            outcome: .success(status: .ok, headers: headersB, body: mockBody)
        )

        let stubDifferentMethod = NetSkeinStub(
            method: .POST,
            url: "https://netskein.mock",
            delay: nil,
            outcome: .success(status: .ok, headers: headersA, body: mockBody)
        )

        let stubDifferentOutcome = NetSkeinStub(
            method: .GET,
            url: "https://netskein.mock",
            delay: nil,
            outcome: .failure(MockStubOutageError())
        )

        let stubDifferentDelay = NetSkeinStub(
            method: .GET,
            url: "https://netskein.mock",
            delay: .seconds(3),  // Injected distinct structural delay
            outcome: .success(status: .ok, headers: headersA, body: mockBody)
        )

        #expect(
            stub1 == stub2,
            "Should match because method, delay, and outcome description fields are identical"
        )
        #expect(
            stub1 != stubDifferentMethod,
            "Should not match due to distinct HTTP method raw values"
        )
        #expect(
            stub1 != stubDifferentOutcome,
            "Should not match due to separate structural outcome variants"
        )
        #expect(
            stub1 != stubDifferentDelay,
            "Should not match because delay properties are structurally separate"
        )
    }

    @Test(
        "NetSkeinStubTests: Ensures that compliant manual hash functions produce stable and predictable hash outputs based on state layout combinations"
    )
    func testStubHashableLogic() {
        // Twin layout configuration mapping stable default nil delays
        let stub1 = NetSkeinStub(
            method: .PUT,
            url: "https://netskein.mock",
            delay: .seconds(5),
            outcome: .success(status: .accepted, headers: HTTPHeaders(), body: nil)
        )

        let stub2 = NetSkeinStub(
            method: .PUT,
            url: "https://netskein.mock-different-ignored-url",
            delay: .seconds(5),  // Matches stub1 delay to produce identical hashes
            outcome: .success(status: .accepted, headers: HTTPHeaders(), body: nil)
        )

        let stubWithDifferentHashDelay = NetSkeinStub(
            method: .PUT,
            url: "https://netskein.mock",
            delay: nil,  // Distinct delay allocation creates a separate hash digest block
            outcome: .success(status: .accepted, headers: HTTPHeaders(), body: nil)
        )

        var hasher1 = Hasher()
        var hasher2 = Hasher()
        var hasher3 = Hasher()

        stub1.hash(into: &hasher1)
        stub2.hash(into: &hasher2)
        stubWithDifferentHashDelay.hash(into: &hasher3)

        #expect(
            hasher1.finalize() == hasher2.finalize(),
            "Identical structural states must yield identical hash outputs"
        )
        #expect(
            hasher1.finalize() != hasher3.finalize(),
            "Altered delay states must produce unique distinct hash digests"
        )
    }
}
