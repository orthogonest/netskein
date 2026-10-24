import AsyncHTTPClient
import NIOHTTP1
import Testing

@testable import NetSkein

struct ProxyTests {
    @Test(
        "ProxyTests: Verifies HTTP proxy factory accurately maps host and port with safe default options"
    )
    func testHTTPProxyInitializationWithDefaults() {
        let expectedHost = "127.0.0.1"
        let expectedPort = 8080

        let proxy = Proxy.http(host: expectedHost, port: expectedPort)
        let underlying = proxy.underlyingProxy

        #expect(underlying.host == expectedHost)
        #expect(underlying.port == expectedPort)
        #expect(underlying.authorization == nil)

        // Verify empty connectHeaders initialize with default HTTPHeaders()
        #expect(underlying.connectHeaders.first(name: "Any-Header") == nil)
    }

    @Test(
        "ProxyTests: Verifies HTTP proxy with authorization token injects credentials correctly"
    )
    func testHTTPProxyWithAuthorization() {
        let expectedHost = "secure-proxy.com"
        let expectedPort = 443
        let mockAuth = HTTPClient.Authorization.basic(username: "admin", password: "password123")

        let proxy = Proxy.http(
            host: expectedHost,
            port: expectedPort,
            authorization: mockAuth
        )
        let underlying = proxy.underlyingProxy

        #expect(underlying.host == expectedHost)
        #expect(underlying.port == expectedPort)
        #expect(underlying.authorization == mockAuth)
    }

    @Test(
        "ProxyTests: Verifies HTTP proxy accurately propagates custom connect headers built via HTTPHeaders"
    )
    func testHTTPProxyWithConnectHeaders() {
        var customHeaders = HTTPHeaders()
        customHeaders.add(name: "X-Proxy-Custom-Routing", value: "cluster-alpha")

        let proxy = Proxy.http(
            host: "proxy.internal",
            port: 3128,
            connectHeaders: customHeaders
        )
        let underlying = proxy.underlyingProxy

        #expect(underlying.connectHeaders.first(name: "X-Proxy-Custom-Routing") == "cluster-alpha")
    }

    @Test(
        "ProxyTests: Verifies SOCKS proxy factory accurately maps host and port to underlying socksServer configuration"
    )
    func testSOCKSProxyInitialization() {
        let expectedHost = "proxy.local"
        let expectedPort = 1080

        let proxy = Proxy.socks(host: expectedHost, port: expectedPort)
        let underlying = proxy.underlyingProxy

        #expect(underlying.host == expectedHost)
        #expect(underlying.port == expectedPort)
        #expect(underlying.authorization == nil)
    }
}
