import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import Testing

@testable import NetSkeinTesting

struct HTTPStubTests {
    struct MockStubOutageError: Error, CustomStringConvertible, Sendable {
        var description: String { "Simulated physical socket dropout error." }
    }

    @Test(
        "HTTPStubTests: Verifies static URL initializer locks precise string matches accurately"
    )
    func testStaticURLInitializer() {
        let stub = HTTPStub(
            method: .GET,
            url: "https://netskein.mock",
            delay: .seconds(2),
            requestValidator: { _ in },
            outcome: .response(status: .ok, headers: HTTPHeaders(), body: nil)
        )

        #expect(stub.method == .GET)
        #expect(stub.delay == .seconds(2))
        #expect(stub.requestValidator != nil)

        // Assert closure behavior for the exact URL matching rule
        #expect(stub.urlMatcher("https://netskein.mock") == true)
        #expect(stub.urlMatcher("https://netskein.mock1") == false)
    }

    @Test(
        "HTTPStubTests: Verifies closure-based urlMatcher initialization captures custom dynamic prefix pattern constraints"
    )
    func testDynamicURLMatcherInitializer() {
        let stub = HTTPStub(
            method: .POST,
            urlMatcher: { @Sendable url in url.hasPrefix("https://netskein.mock") },
            delay: nil,
            requestValidator: nil,
            outcome: .error(MockStubOutageError())
        )

        #expect(stub.method == .POST)
        #expect(stub.delay == nil)
        #expect(stub.requestValidator == nil)

        // Validate regex/closure execution path bounds
        #expect(stub.urlMatcher("https://netskein.mock42") == true)
        #expect(stub.urlMatcher("https://netskeins.mock") == false)
    }

}
