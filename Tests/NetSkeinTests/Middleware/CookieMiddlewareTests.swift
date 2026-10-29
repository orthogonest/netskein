import AsyncHTTPClient
import Logging
import NIOConcurrencyHelpers
import NIOHTTP1
import Testing

@testable import NetSkein
@testable import NetSkeinTesting

struct CookieMiddlewareTests {}

// MARK: - Client Integration

extension CookieMiddlewareTests {
    @Test(
        "CookieMiddlewareTests: Verifies the jar's cookies are sent and valid Set-Cookie headers are stored"
    )
    func testSendsAndStoresCookies() async throws {
        let jar = CookieJar()
        jar.setCookie(host: "api.example.com", name: "session_id", value: "token_123")

        let sentCookie = NIOLockedValueBox<String?>(nil)

        var responseHeaders = HTTPHeaders()
        responseHeaders.add(name: "Set-Cookie", value: "user=octocat; Path=/; Secure")
        responseHeaders.add(name: "Set-Cookie", value: "malformed_cookie_no_equal_sign")

        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/profile",
            requestValidator: { request in
                sentCookie.withLockedValue { $0 = request.headers.first(name: "Cookie") }
            },
            outcome: .response(status: .ok, headers: responseHeaders, body: nil)
        )
        let client = NetSkeinClient.testing().cookieJar(jar).addStub(stub).build()

        _ = try await client.get("https://api.example.com/profile").send()

        #expect(sentCookie.withLockedValue { $0 } == "session_id=token_123")
        #expect(jar.cookieHeader(for: "api.example.com")?.contains("user=octocat") == true)
        #expect(jar.cookieHeader(for: "api.example.com")?.contains("malformed") == false)
    }

    @Test("CookieMiddlewareTests: Verifies client middleware sees the Cookie header")
    func testRunsBeforeClientMiddleware() async throws {
        let jar = CookieJar()
        jar.setCookie(host: "api.example.com", name: "session_id", value: "token_123")

        let seenCookie = NIOLockedValueBox<String?>(nil)
        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/profile",
            outcome: .response(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing()
            .cookieJar(jar)
            .using { request, _, next in
                seenCookie.withLockedValue { $0 = request.headers.first(name: "Cookie") }
                return try await next(request)
            }
            .addStub(stub)
            .build()

        _ = try await client.get("https://api.example.com/profile").send()

        #expect(seenCookie.withLockedValue { $0 } == "session_id=token_123")
    }

    @Test("CookieMiddlewareTests: Verifies no cookie middleware is added without a jar")
    func testNotAddedWithoutJar() {
        let client = NetSkeinClient.testing().build()

        #expect(!client.middlewares.contains { $0 is CookieMiddleware })
    }
}

// MARK: - Requests Without a Host

extension CookieMiddlewareTests {
    @Test("CookieMiddlewareTests: Verifies a URL without a host passes through untouched")
    func testURLWithoutHostPassesThrough() async throws {
        let jar = CookieJar()
        jar.setCookie(host: "api.example.com", name: "session_id", value: "token_123")
        let sentHeaders = NIOLockedValueBox<HTTPHeaders>([:])

        let response = try await CookieMiddleware(jar: jar)
            .intercept(
                RequestHead(method: .GET, url: "/relative/path", headers: [:]),
                context: .testing()
            ) { request in
                sentHeaders.withLockedValue { $0 = request.headers }
                return HTTPClientResponse(status: .ok, headers: ["Set-Cookie": "user=octocat"])
            }

        #expect(response.status == .ok)
        #expect(sentHeaders.withLockedValue { $0 }.contains(name: "Cookie") == false)
        #expect(jar.cookieHeader(for: "api.example.com") == "session_id=token_123")
    }
}
