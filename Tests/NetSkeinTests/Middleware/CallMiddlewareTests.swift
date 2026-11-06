import AsyncHTTPClient
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import Testing

@testable import NetSkein
@testable import NetSkeinTesting

/// Middleware registered `per: .call`, which runs once around all attempts of a call.
struct CallMiddlewareTests {
    let url = "https://api.example.com/call"

    struct Dropped: Error {}

    /// A 503 followed by a 200 with `body`, retried once without waiting.
    func retriedClient(
        body: String = "ok",
        configure: (TestClientBuilder) -> TestClientBuilder = { $0 }
    ) -> NetSkeinClient {
        configure(
            NetSkeinClient.testing()
                .retryPolicy(.standard(maxRetries: 1, backoff: .immediate))
                .addStub(HTTPStub.get(url).status(.serviceUnavailable))
                .addStub(HTTPStub.get(url).text(body))
        )
        .build()
    }
}

// MARK: - Once per Call

extension CallMiddlewareTests {
    @Test(
        "CallMiddlewareTests: call middleware runs once while attempt middleware runs per attempt"
    )
    func testRunsOncePerCall() async throws {
        let callRuns = NIOLockedValueBox<[Int]>([])
        let attemptRuns = NIOLockedValueBox<[Int]>([])
        let finalStatus = NIOLockedValueBox<HTTPResponseStatus?>(nil)

        let client = retriedClient {
            $0.using(per: .call) { request, context, next in
                callRuns.withLockedValue { $0.append(context.attempt) }
                let response = try await next(request)
                finalStatus.withLockedValue { $0 = response.status }
                return response
            }
            .using { request, context, next in
                attemptRuns.withLockedValue { $0.append(context.attempt) }
                return try await next(request)
            }
        }

        let response = try await client.get(url).send()

        #expect(response.text() == "ok")
        #expect(callRuns.withLockedValue { $0 } == [0])
        #expect(attemptRuns.withLockedValue { $0 } == [0, 1])
        #expect(finalStatus.withLockedValue { $0 } == .ok)
    }

    @Test("CallMiddlewareTests: a header added per call reaches every attempt unchanged")
    func testHeaderReachesEveryAttempt() async throws {
        let keys = NIOLockedValueBox<[String]>([])

        let client = retriedClient {
            $0.using(per: .call) { request, _, next in
                var request = request
                request.headers.add(name: "Idempotency-Key", value: UUID().uuidString)
                return try await next(request)
            }
            .using { request, _, next in
                keys.withLockedValue {
                    $0.append(request.headers.first(name: "Idempotency-Key") ?? "")
                }
                return try await next(request)
            }
        }

        _ = try await client.get(url).send()

        let sent = keys.withLockedValue { $0 }
        #expect(sent.count == 2)
        #expect(Set(sent).count == 1)
        #expect(sent.first?.isEmpty == false)
    }

    @Test("CallMiddlewareTests: client call middleware wraps request call middleware")
    func testClientWrapsRequest() async throws {
        let order = NIOLockedValueBox<[String]>([])

        let client = NetSkeinClient.testing()
            .using(per: .call) { request, _, next in
                order.withLockedValue { $0.append("client") }
                return try await next(request)
            }
            .addStub(HTTPStub.get(url).text("ok"))
            .build()

        _ = try await client.get(url)
            .using(per: .call) { request, _, next in
                order.withLockedValue { $0.append("request") }
                return try await next(request)
            }
            .send()

        #expect(order.withLockedValue { $0 } == ["client", "request"])
    }
}

// MARK: - Answering Without next

extension CallMiddlewareTests {
    @Test("CallMiddlewareTests: a response returned without next ends the call with it")
    func testShortCircuit() async throws {
        // No stubs: reaching the transport would fail the call
        let client = NetSkeinClient.testing()
            .using(per: .call) { _, _, _ in
                HTTPClientResponse(status: .ok, body: .bytes(ByteBuffer(string: "local")))
            }
            .build()

        let response = try await client.get(url).send()

        #expect(response.text() == "local")
    }

    @Test("CallMiddlewareTests: a fallback returned after next throws ends the call with it")
    func testFallbackAfterFailure() async throws {
        let client = NetSkeinClient.testing()
            .using(per: .call) { request, _, next in
                do {
                    return try await next(request)
                } catch {
                    return HTTPClientResponse(
                        status: .ok,
                        body: .bytes(ByteBuffer(string: "fallback"))
                    )
                }
            }
            .addStub(HTTPStub.get(url).fail(with: Dropped()))
            .build()

        let response = try await client.get(url).send()

        #expect(response.text() == "fallback")
    }

    @Test("CallMiddlewareTests: a failure passed on by call middleware reaches the caller")
    func testFailurePassedOn() async {
        let client = NetSkeinClient.testing()
            .using(per: .call) { request, _, next in try await next(request) }
            .addStub(HTTPStub.get(url).fail(with: Dropped()))
            .build()

        await #expect {
            _ = try await client.get(url).send()
        } throws: { error in
            (error as? NetSkeinError)?.kind == .networkFailure
        }
    }

    @Test("CallMiddlewareTests: changing the response returned by next has no effect")
    func testReplacedResponseIgnored() async throws {
        let client = NetSkeinClient.testing()
            .using(per: .call) { request, _, next in
                var response = try await next(request)
                response.status = .notFound
                return response
            }
            .addStub(HTTPStub.get(url).text("ok"))
            .build()

        let response = try await client.get(url).send()

        #expect(response.status == .ok)
    }
}

// MARK: - What next Returns

extension CallMiddlewareTests {
    @Test("CallMiddlewareTests: for send, next returns the collected body, or none when empty")
    func testSendResponse() async throws {
        let bodies = NIOLockedValueBox<[String]>([])
        let client = NetSkeinClient.testing()
            .using(per: .call) { request, _, next in
                let response = try await next(request)
                let body = try await response.body.collect(upTo: 1024)
                bodies.withLockedValue { $0.append(String(buffer: body)) }
                return response
            }
            .addStub(HTTPStub.get(url).text("collected"))
            .addStub(HTTPStub.get(url).status(.noContent))
            .build()

        _ = try await client.get(url).send()
        _ = try await client.get(url).send()

        #expect(bodies.withLockedValue { $0 } == ["collected", ""])
    }

    @Test("CallMiddlewareTests: for stream(), the body is left for the caller to read")
    func testOpenStreamResponse() async throws {
        let status = NIOLockedValueBox<HTTPResponseStatus?>(nil)
        let client = NetSkeinClient.testing()
            .using(per: .call) { request, _, next in
                let response = try await next(request)
                status.withLockedValue { $0 = response.status }
                return response
            }
            .addStub(HTTPStub.get(url).text("streamed"))
            .build()

        var received = ""
        for try await chunk in try await client.get(url).stream() {
            received += String(buffer: chunk)
        }

        #expect(status.withLockedValue { $0 } == .ok)
        #expect(received == "streamed")
    }

    @Test("CallMiddlewareTests: for stream(_:) and downloads, next returns the head only")
    func testDeliveredBodyResponses() async throws {
        let seen = NIOLockedValueBox<[(HTTPResponseStatus, String?, Int)]>([])
        let client = NetSkeinClient.testing()
            .using(per: .call) { request, _, next in
                let response = try await next(request)
                let body = try await response.body.collect(upTo: 1024)
                seen.withLockedValue {
                    $0.append(
                        (
                            response.status, response.headers.first(name: "X-Test"),
                            body.readableBytes
                        )
                    )
                }
                return response
            }
            .addStub(HTTPStub.get(url).header("X-Test", "stream").text("chunk"))
            .addStub(HTTPStub.get(url).header("X-Test", "download").text("file"))
            .build()

        let chunks = NIOLockedValueBox(0)
        _ = try await client.get(url).stream { _, _, _ in chunks.withLockedValue { $0 += 1 } }

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("call_middleware_\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await client.get(url).download(toFileAtPath: path)

        let results = seen.withLockedValue { $0 }
        #expect(results.map(\.0) == [.ok, .ok])
        #expect(results.map(\.1) == ["stream", "download"])
        #expect(results.map(\.2) == [0, 0])
        #expect(chunks.withLockedValue { $0 } == 1)
        #expect(FileManager.default.contents(atPath: path) == Data("file".utf8))
    }
}
