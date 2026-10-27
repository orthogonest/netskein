import AsyncHTTPClient
import Logging
import NIOConcurrencyHelpers
import NIOHTTP1
import Testing

@testable import NetSkein
@testable import NetSkeinTesting

struct MiddlewareChainTests {
    @Test("MiddlewareChainTests: Verifies middleware runs in onion order around the transport")
    func testOnionOrdering() async throws {
        let events = NIOLockedValueBox<[String]>([])

        let response = try await MiddlewareChain.run(
            makeHead(),
            through: [
                RecordingMiddleware(name: "outer", events: events),
                RecordingMiddleware(name: "inner", events: events),
            ],
            context: makeContext(),
            transport: { _ in
                events.withLockedValue { $0.append("transport") }
                return HTTPClientResponse(status: .ok)
            }
        )

        #expect(response.status == .ok)
        #expect(
            events.withLockedValue { $0 }
                == [
                    "outer:request", "inner:request", "transport", "inner:response",
                    "outer:response",
                ]
        )
    }

    @Test("MiddlewareChainTests: Verifies an empty chain calls the transport directly")
    func testEmptyChainCallsTransport() async throws {
        let response = try await MiddlewareChain.run(
            makeHead(),
            through: [],
            context: makeContext(),
            transport: { _ in HTTPClientResponse(status: .accepted) }
        )

        #expect(response.status == .accepted)
    }

    @Test("MiddlewareChainTests: Verifies changes to the request head reach the transport")
    func testHeadChangesReachTransport() async throws {
        let receivedHeader = NIOLockedValueBox<String?>(nil)
        let addHeader = ClosureMiddleware { request, _, next in
            var request = request
            request.headers.replaceOrAdd(name: "X-Added", value: "yes")
            return try await next(request)
        }

        _ = try await MiddlewareChain.run(
            makeHead(),
            through: [addHeader],
            context: makeContext(),
            transport: { head in
                receivedHeader.withLockedValue { $0 = head.headers.first(name: "X-Added") }
                return HTTPClientResponse(status: .ok)
            }
        )

        #expect(receivedHeader.withLockedValue { $0 } == "yes")
    }

    @Test(
        "MiddlewareChainTests: Verifies middleware can short-circuit without calling the transport"
    )
    func testShortCircuit() async throws {
        let transportCalls = NIOLockedValueBox(0)
        let cached = ClosureMiddleware { _, _, _ in HTTPClientResponse(status: .notModified) }

        let response = try await MiddlewareChain.run(
            makeHead(),
            through: [cached],
            context: makeContext(),
            transport: { _ in
                transportCalls.withLockedValue { $0 += 1 }
                return HTTPClientResponse(status: .ok)
            }
        )

        #expect(response.status == .notModified)
        #expect(transportCalls.withLockedValue { $0 } == 0)
    }

    @Test(
        "MiddlewareChainTests: Verifies a middleware's own error is reported as middlewareFailure"
    )
    func testOwnErrorBecomesMiddlewareFailure() async {
        let failing = ClosureMiddleware { _, _, _ in throw MiddlewareOwnError() }

        do {
            _ = try await MiddlewareChain.run(
                makeHead(),
                through: [failing],
                context: makeContext(),
                transport: { _ in HTTPClientResponse(status: .ok) }
            )
            Issue.record("Expected the chain to throw .middlewareFailure")
        } catch let error as NetSkeinError {
            #expect(error.kind == .middlewareFailure)
            #expect(error.errorDescription?.contains("ClosureMiddleware failed") == true)
        } catch {
            Issue.record("Expected NetSkeinError, got \(error)")
        }
    }

    @Test(
        "MiddlewareChainTests: Verifies transport errors pass through middleware unchanged"
    )
    func testTransportErrorPassesThrough() async {
        let passThrough = ClosureMiddleware { request, _, next in try await next(request) }

        do {
            _ = try await MiddlewareChain.run(
                makeHead(),
                through: [passThrough, passThrough],
                context: makeContext(),
                transport: { _ in throw NetSkeinError.simple(.networkFailure) }
            )
            Issue.record("Expected the transport error to propagate")
        } catch let error as NetSkeinError {
            #expect(error == NetSkeinError.simple(.networkFailure))
        } catch {
            Issue.record("Expected NetSkeinError, got \(error)")
        }
    }

    @Test("MiddlewareChainTests: Verifies a NetSkeinError thrown by middleware is kept as is")
    func testMiddlewareNetSkeinErrorIsKept() async {
        let rejecting = ClosureMiddleware { _, _, _ in throw NetSkeinError.simple(.clientError) }

        do {
            _ = try await MiddlewareChain.run(
                makeHead(),
                through: [rejecting],
                context: makeContext(),
                transport: { _ in HTTPClientResponse(status: .ok) }
            )
            Issue.record("Expected the middleware's NetSkeinError to propagate")
        } catch let error as NetSkeinError {
            #expect(error == NetSkeinError.simple(.clientError))
        } catch {
            Issue.record("Expected NetSkeinError, got \(error)")
        }
    }
}

// MARK: - Test Helpers

extension MiddlewareChainTests {
    private func makeHead() -> RequestHead {
        RequestHead(method: .GET, url: "https://api.example.com/items", headers: [:])
    }

    private func makeContext() -> MiddlewareContext {
        MiddlewareContext(
            attempt: 0,
            requestID: "request-id",
            logger: Logger(label: LoggerLabel.test),
            body: .none
        )
    }
}

private struct MiddlewareOwnError: Error {}

private struct RecordingMiddleware: HTTPMiddleware {
    let name: String
    let events: NIOLockedValueBox<[String]>

    func intercept(
        _ request: RequestHead,
        context: MiddlewareContext,
        next: Next
    ) async throws -> HTTPClientResponse {
        events.withLockedValue { $0.append("\(name):request") }
        let response = try await next(request)
        events.withLockedValue { $0.append("\(name):response") }
        return response
    }
}
