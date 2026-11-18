import Foundation
import NIOConcurrencyHelpers
import NIOHTTP1
import Testing

@testable import NetSkein

/// Requests that can't be sent as built, refused by AsyncHTTPClient before anything is sent.
struct InvalidRequestTests {
    @Test(
        "InvalidRequestTests: a URL the transport refuses fails once with invalidRequest",
        arguments: [
            "//api.example.com/users",  // No scheme
            "ftp://api.example.com/users",  // Unsupported scheme
            "http:///users",  // No host
        ]
    )
    func testRefusedURL(url: String) async throws {
        let attempts = NIOLockedValueBox(0)
        let breaker = CircuitBreaker(failureThreshold: 1)
        let client = NetSkeinClientBuilder()
            .retryPolicy(.standard(backoff: .immediate))
            .circuitBreaker(breaker)
            .using { request, _, next in
                attempts.withLockedValue { $0 += 1 }
                return try await next(request)
            }
            .build()

        do {
            _ = try await client.get(url).send()
            Issue.record("Expected send() to throw invalidRequest")
        } catch {
            #expect(error.kind == .invalidRequest)
            #expect(error.failureReason != nil)
        }

        #expect(attempts.withLockedValue { $0 } == 1)
        let key = CircuitBreaker.origin(of: RequestHead(method: .GET, url: url, headers: [:]))
        #expect(breaker.state(for: key) == .closed)
        try await client.shutdown()
    }
}
