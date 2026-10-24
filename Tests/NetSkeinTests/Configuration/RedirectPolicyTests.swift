import AsyncHTTPClient
import Testing

@testable import NetSkein

struct RedirectPolicyTests {
    @Test(
        "RedirectPolicyTests: Verifies default case maps to correct follow max constraint"
    )
    func testDefaultRedirectPolicy() {
        let policy = RedirectPolicy.default
        let expectedConfig = HTTPClient.Configuration.RedirectConfiguration.follow(
            max: 5,
            allowCycles: false
        )

        assertEqual(policy.underlyingConfiguration, expectedConfig)
    }

    @Test("RedirectPolicyTests: Verifies none case completely disallows redirect behaviors")
    func testNoneRedirectPolicy() {
        let policy = RedirectPolicy.disabled
        let expectedConfig = HTTPClient.Configuration.RedirectConfiguration.disallow

        assertEqual(policy.underlyingConfiguration, expectedConfig)
    }

    @Test(
        "RedirectPolicyTests: Verifies positive limited bounds assign explicit numeric caps"
    )
    func testPositiveLimitedRedirectPolicy() {
        let customLimit = 3
        let policy = RedirectPolicy.limited(maxRedirects: customLimit)
        let expectedConfig = HTTPClient.Configuration.RedirectConfiguration.follow(
            max: customLimit,
            allowCycles: false
        )

        assertEqual(policy.underlyingConfiguration, expectedConfig)
    }

    @Test(
        "RedirectPolicyTests: Verifies non-positive limited bounds fallback gracefully to disallow behavior"
    )
    func testNegativeAndZeroLimitedRedirectPolicy() {
        // Test Zero limit constraint
        let zeroPolicy = RedirectPolicy.limited(maxRedirects: 0)
        let expectedZeroConfig = HTTPClient.Configuration.RedirectConfiguration.disallow
        assertEqual(zeroPolicy.underlyingConfiguration, expectedZeroConfig)

        // Test Negative limit constraint
        let negativePolicy = RedirectPolicy.limited(maxRedirects: -5)
        let expectedNegativeConfig = HTTPClient.Configuration.RedirectConfiguration.disallow
        assertEqual(negativePolicy.underlyingConfiguration, expectedNegativeConfig)
    }
}

extension RedirectPolicyTests {
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
