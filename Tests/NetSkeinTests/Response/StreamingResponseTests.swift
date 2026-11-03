import AsyncHTTPClient
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import Testing

@testable import NetSkein
@testable import NetSkeinTesting

struct StreamingResponseTests {
    let url = "https://api.example.com/stream"

    struct Dropped: Error {}

    /// A client whose transport answers with `replies`, one per request.
    func makeClient(
        _ replies: [ChunkedTransport.Reply],
        retryPolicy: RetryPolicy = .disabled
    ) -> (NetSkeinClient, ChunkedTransport) {
        let transport = ChunkedTransport(replies)
        let client = NetSkeinClient(
            transport: transport,
            retryPolicy: retryPolicy,
            tracer: nil,
            logger: Logger(label: LoggerLabel.test)
        )
        return (client, transport)
    }

    /// All lines of a body delivered in `chunks`.
    func lines(of chunks: [[UInt8]], maxLineLength: Int? = 1024) async throws -> [String] {
        let (client, _) = makeClient([.chunks(chunks.map { ByteBuffer(bytes: $0) })])
        var lines: [String] = []
        for try await line in try await client.get(url).lines(maxLineLength: maxLineLength) {
            lines.append(line)
        }
        return lines
    }
}

// MARK: - Stream

extension StreamingResponseTests {
    @Test("StreamingResponseTests: stream delivers the chunks in order, with the response head")
    func testStreamChunks() async throws {
        let (client, _) = makeClient([
            .chunks(
                [ByteBuffer(string: "ab"), ByteBuffer(string: "cd")],
                headers: ["Content-Length": "4"]
            )
        ])

        let response = try await client.get(url).stream()
        var chunks: [String] = []
        for try await chunk in response { chunks.append(String(buffer: chunk)) }

        #expect(response.status == .ok)
        #expect(response.headers.first(name: "Content-Length") == "4")
        #expect(response.expectedContentLength == 4)
        #expect(chunks == ["ab", "cd"])
    }

    @Test("StreamingResponseTests: a response without Content-Length has no expected length")
    func testNoContentLength() async throws {
        let (client, _) = makeClient([.chunks([])])

        #expect(try await client.get(url).stream().expectedContentLength == nil)
    }

    @Test("StreamingResponseTests: a status outside 200..<300 throws before the body is read")
    func testBadStatus() async throws {
        let (client, _) = makeClient([
            .chunks([ByteBuffer(string: "oops")], status: .internalServerError)
        ])

        await #expect {
            _ = try await client.get(url).stream()
        } throws: { error in
            (error as? NetSkeinError)?.kind == .serverError
        }
    }

    @Test("StreamingResponseTests: failures before the headers arrive are retried")
    func testRetryBeforeHeaders() async throws {
        let (client, transport) = makeClient(
            [.chunks([], status: .serviceUnavailable), .chunks([ByteBuffer(string: "ok")])],
            retryPolicy: .standard(maxRetries: 1, backoff: .immediate)
        )

        let response = try await client.get(url).stream()

        #expect(response.status == .ok)
        #expect(transport.requestCount == 2)
    }

    @Test("StreamingResponseTests: a failure while reading the body is thrown, never retried")
    func testFailureWhileReading() async throws {
        let (client, transport) = makeClient(
            [.chunks([ByteBuffer(string: "first")], failure: Dropped())],
            retryPolicy: .standard(maxRetries: 3, backoff: .immediate)
        )

        let response = try await client.get(url).stream()
        var received: [String] = []
        await #expect {
            for try await chunk in response { received.append(String(buffer: chunk)) }
        } throws: { error in
            (error as? NetSkeinError)?.kind == .networkFailure
        }

        #expect(received == ["first"])
        #expect(transport.requestCount == 1)
    }

    @Test("StreamingResponseTests: a cancelled task stops reading with an error")
    func testCancellation() async throws {
        let (client, _) = makeClient([.chunks([ByteBuffer(string: "a"), ByteBuffer(string: "b")])])
        let response = try await client.get(url).stream()

        let reading = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            for try await _ in response {}
        }

        await #expect {
            try await reading.value
        } throws: { error in
            (error as? NetSkeinError)?.kind == .networkFailure
        }
    }

    @Test("StreamingResponseTests: a body cancelled while being read is reported, not cut short")
    func testCancellationEndingTheBody() async throws {
        let response = NetSkeinStream(
            HTTPClientResponse(status: .ok, body: .stream(CancellingBody()))
        )

        let reading = Task {
            var count = 0
            for try await _ in response { count += 1 }
            return count
        }

        await #expect(throws: NetSkeinError.self) {
            _ = try await reading.value
        }
    }
}

// MARK: - Lines

extension StreamingResponseTests {
    @Test("StreamingResponseTests: lines split on \\n, \\r\\n and \\r, also across chunks")
    func testLineEndings() async throws {
        let chunks = ["a\nb", "c\r\n", "d\r", "\ne\n\nf"].map { Array($0.utf8) }

        #expect(try await lines(of: chunks) == ["a", "bc", "d", "e", "", "f"])
    }

    @Test(
        "StreamingResponseTests: lines end where the body ends, without an extra empty line",
        arguments: [
            (["a\n"], ["a"]),
            (["a"], ["a"]),
            (["x\r"], ["x"]),
            (["\n"], [""]),
            ([], [String]()),
        ]
    )
    func testBodyEnd(chunks: [String], expected: [String]) async throws {
        #expect(try await lines(of: chunks.map { Array($0.utf8) }) == expected)
    }

    @Test(
        "StreamingResponseTests: UTF-8 split across chunks stays intact, invalid bytes are replaced"
    )
    func testUTF8() async throws {
        // "é" is 0xC3 0xA9; 0xFF is never valid UTF-8
        let chunks: [[UInt8]] = [[0x63, 0x61, 0x66, 0xC3], [0xA9, 0x0A, 0xFF, 0x0A]]

        #expect(try await lines(of: chunks) == ["café", "\u{FFFD}"])
    }

    @Test(
        "StreamingResponseTests: a line longer than the limit throws, even when it spans chunks",
        arguments: [["abcde\n"], ["ab", "cde\n"], ["abcde"]]
    )
    func testLineLimit(chunks: [String]) async throws {
        await #expect {
            _ = try await lines(of: chunks.map { Array($0.utf8) }, maxLineLength: 4)
        } throws: { error in
            (error as? NetSkeinError)?.kind == .invalidPayload
        }
    }

    @Test("StreamingResponseTests: lines expose the response head and can stop early")
    func testLinesHeadAndBreak() async throws {
        let (client, _) = makeClient([
            .chunks(
                [ByteBuffer(string: "one\ntwo\nthree\n")],
                headers: ["Content-Type": "application/x-ndjson"]
            )
        ])

        let lines = try await client.get(url).stream().lines()
        var first: String?
        for try await line in lines {
            first = line
            break
        }

        #expect(lines.status == .ok)
        #expect(lines.headers.first(name: "Content-Type") == "application/x-ndjson")
        #expect(first == "one")
    }
}

// MARK: - With Other Features

extension StreamingResponseTests {
    @Test("StreamingResponseTests: streamed responses bypass the cache, and middleware sees them")
    func testCacheAndMiddleware() async throws {
        let seenStatus = NIOLockedValueBox<HTTPResponseStatus?>(nil)
        let client = NetSkeinClient.testing()
            .cache(.testing(clock: TestClock()))
            .using { request, _, next in
                let response = try await next(request)
                seenStatus.withLockedValue { $0 = response.status }
                return response
            }
            .addStub(HTTPStub.get(url).header("Cache-Control", "max-age=60").text("line\n"))
            .build()

        let lines = try await client.get(url).lines()

        #expect(lines.headers.first(name: "Cache-Status") == "NetSkein; fwd=bypass")
        #expect(seenStatus.withLockedValue { $0 } == .ok)
    }
}

// MARK: - Limits

extension StreamingResponseTests {
    @Test("StreamingResponseTests: lines accept any length when the limit is removed")
    func testUnlimitedLines() async throws {
        let long = [UInt8](repeating: UInt8(ascii: "x"), count: 2 * 1024 * 1024)
        let (client, _) = makeClient([.chunks([ByteBuffer(bytes: long)])])

        var lengths: [Int] = []
        for try await line in try await client.get(url).lines(maxLineLength: nil) {
            lengths.append(line.utf8.count)
        }

        #expect(lengths == [long.count])
    }

    @Test("StreamingResponseTests: send accepts any body size when maxResponseBytes is removed")
    func testUnlimitedResponseBytes() async throws {
        let client = NetSkeinClient.testing().addStub(HTTPStub.get(url).text("too long")).build()

        await #expect(throws: NetSkeinError.self) {
            _ = try await client.get(url).maxResponseBytes(3).send()
        }
        let response = try await client.get(url).maxResponseBytes(3).maxResponseBytes(nil).send()

        #expect(response.text() == "too long")
    }
}

// MARK: - Transports

/// Answers each request with the next reply, delivering its body in the given chunks.
final class ChunkedTransport: HTTPTransport {
    enum Reply: Sendable {
        case chunks(
            [ByteBuffer],
            status: HTTPResponseStatus = .ok,
            headers: HTTPHeaders = [:],
            failure: (any Error & Sendable)? = nil
        )
    }

    struct UnexpectedRequest: Error {}

    private let replies: NIOLockedValueBox<[Reply]>
    private let count = NIOLockedValueBox(0)

    init(_ replies: [Reply]) {
        self.replies = NIOLockedValueBox(replies)
    }

    var requestCount: Int { count.withLockedValue { $0 } }

    func execute(
        _ request: HTTPClientRequest,
        timeout: TimeAmount,
        logger: Logger?
    ) async throws -> HTTPClientResponse {
        count.withLockedValue { $0 += 1 }
        guard
            case let .chunks(chunks, status, headers, failure) = replies.withLockedValue({
                $0.isEmpty ? nil : $0.removeFirst()
            })
        else { throw UnexpectedRequest() }

        let body = AsyncThrowingStream<ByteBuffer, any Error> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish(throwing: failure)
        }
        return HTTPClientResponse(status: status, headers: headers, body: .stream(body))
    }

    func shutdown() async throws {}
}

/// A body that cancels the task reading it, then ends as if complete.
private struct CancellingBody: AsyncSequence, Sendable {
    typealias Element = ByteBuffer

    struct AsyncIterator: AsyncIteratorProtocol {
        mutating func next() async throws -> ByteBuffer? {
            withUnsafeCurrentTask { $0?.cancel() }
            return nil
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator() }
}
