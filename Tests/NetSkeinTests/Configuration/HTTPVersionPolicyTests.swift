import AsyncHTTPClient
import Testing

@testable import NetSkein

struct HTTPVersionPolicyTests {
    @Test(
        "HTTPVersionPolicyTests: Verifies each policy maps to the matching transport version",
        arguments: [
            (HTTPVersionPolicy.automatic, HTTPClient.Configuration.HTTPVersion.automatic),
            (.http1Only, .http1Only),
        ]
    )
    func testUnderlyingVersion(
        policy: HTTPVersionPolicy,
        expected: HTTPClient.Configuration.HTTPVersion
    ) {
        #expect(policy.underlyingVersion == expected)
    }
}
