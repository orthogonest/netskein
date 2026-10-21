import AsyncHTTPClient
import Testing

@testable import NetSkein

struct NetSkeinRedirectPolicyTests {
    @Test(
        "NetSkeinRedirectPolicyTests: Verifies default case maps to correct follow max constraint"
    )
    func testDefaultRedirectPolicy() {
        let policy = NetSkeinRedirectPolicy.default
        let expectedConfig = HTTPClient.Configuration.RedirectConfiguration.follow(
            max: 5,
            allowCycles: false
        )

        assertEqual(policy.underlyingConfiguration, expectedConfig)
    }

    @Test("NetSkeinRedirectPolicyTests: Verifies none case completely disallows redirect behaviors")
    func testNoneRedirectPolicy() {
        let policy = NetSkeinRedirectPolicy.none
        let expectedConfig = HTTPClient.Configuration.RedirectConfiguration.disallow

        assertEqual(policy.underlyingConfiguration, expectedConfig)
    }

    @Test(
        "NetSkeinRedirectPolicyTests: Verifies positive limited bounds assign explicit numeric caps"
    )
    func testPositiveLimitedRedirectPolicy() {
        let customLimit = 3
        let policy = NetSkeinRedirectPolicy.limited(customLimit)
        let expectedConfig = HTTPClient.Configuration.RedirectConfiguration.follow(
            max: customLimit,
            allowCycles: false
        )

        assertEqual(policy.underlyingConfiguration, expectedConfig)
    }

    @Test(
        "NetSkeinRedirectPolicyTests: Verifies non-positive limited bounds fallback gracefully to disallow behavior"
    )
    func testNegativeAndZeroLimitedRedirectPolicy() {
        // Test Zero limit constraint
        let zeroPolicy = NetSkeinRedirectPolicy.limited(0)
        let expectedZeroConfig = HTTPClient.Configuration.RedirectConfiguration.disallow
        assertEqual(zeroPolicy.underlyingConfiguration, expectedZeroConfig)

        // Test Negative limit constraint
        let negativePolicy = NetSkeinRedirectPolicy.limited(-5)
        let expectedNegativeConfig = HTTPClient.Configuration.RedirectConfiguration.disallow
        assertEqual(negativePolicy.underlyingConfiguration, expectedNegativeConfig)
    }
}

extension NetSkeinRedirectPolicyTests {
    private func assertEqual(
        _ lhs: HTTPClient.Configuration.RedirectConfiguration,
        _ rhs: HTTPClient.Configuration.RedirectConfiguration,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let lhsDescription = String(describing: lhs)
        let rhsDescription = String(describing: rhs)

        #expect(lhsDescription == rhsDescription, sourceLocation: sourceLocation)
    }
}
