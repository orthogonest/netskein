// No `@testable`: these tests use only the API available to NetSkein users
import AsyncHTTPClient
import NIOConcurrencyHelpers
import NetSkein
import NetSkeinTesting
import Testing

struct MiddlewareTestingTests {
    @Test(
        "MiddlewareTestingTests: Verifies middleware can be unit-tested by calling intercept directly"
    )
    func testInterceptDirectly() async throws {
        let middleware = AuthMiddleware(tokens: FakeTokenStore())

        let response = try await middleware.intercept(
            RequestHead(method: .GET, url: "https://api.example.com/me", headers: [:]),
            context: .testing()
        ) { request in
            #expect(request.headers.first(name: "Authorization") == "Bearer old")
            return HTTPClientResponse(status: .ok)
        }

        #expect(response.status == .ok)
    }

    @Test(
        "MiddlewareTestingTests: Verifies middleware can be tested end to end with a test client"
    )
    func testThroughTestClient() async throws {
        let sentTokens = NIOLockedValueBox<[String]>([])
        let recordToken: HTTPStub.Validator = { request in
            let token = request.headers.first(name: "Authorization") ?? ""
            sentTokens.withLockedValue { $0.append(token) }
        }
        let client = NetSkeinClient.testing()
            .using(AuthMiddleware(tokens: FakeTokenStore()))
            .addStubs([
                HTTPStub(
                    method: .GET,
                    url: "https://api.example.com/me",
                    requestValidator: recordToken,
                    outcome: .response(status: .unauthorized, headers: [:])
                ),
                HTTPStub(
                    method: .GET,
                    url: "https://api.example.com/me",
                    requestValidator: recordToken,
                    outcome: .response(status: .ok, headers: [:])
                ),
            ])
            .build()

        let response = try await client.get("https://api.example.com/me").send()

        #expect(response.status == .ok)
        #expect(sentTokens.withLockedValue { $0 } == ["Bearer old", "Bearer new"])
        try await client.shutdown()
    }
}

// MARK: - Test Helpers

/// A typical user-written middleware: attaches a token and refreshes it once on 401.
private struct AuthMiddleware: HTTPMiddleware {
    let tokens: FakeTokenStore

    func intercept(
        _ request: RequestHead,
        context: MiddlewareContext,
        next: Next
    ) async throws -> HTTPClientResponse {
        var request = request
        request.headers.replaceOrAdd(name: "Authorization", value: "Bearer \(tokens.current())")
        let response = try await next(request)
        guard response.status == .unauthorized else { return response }

        tokens.refresh()
        request.headers.replaceOrAdd(name: "Authorization", value: "Bearer \(tokens.current())")
        return try await next(request)
    }
}

private final class FakeTokenStore: Sendable {
    private let token = NIOLockedValueBox("old")

    func current() -> String { token.withLockedValue { $0 } }
    func refresh() { token.withLockedValue { $0 = "new" } }
}
