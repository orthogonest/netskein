import AsyncHTTPClient
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import Testing

@testable import NetSkein

struct CurlLoggingMiddlewareTests {
    @Test(
        "CurlLoggingMiddlewareTests: Verifies a request without a body renders method, URL and headers"
    )
    func testRendersHeadWithoutBody() {
        let command = CurlLoggingMiddleware()
            .command(
                for: makeHead(headers: ["Accept": "application/json", "X-Request-ID": "abc"]),
                body: .none
            )

        #expect(
            command
                == "curl -X GET 'https://api.example.com/items' -H 'Accept: application/json' -H 'X-Request-ID: abc'"
        )
    }

    @Test("CurlLoggingMiddlewareTests: Verifies redacted headers are matched case-insensitively")
    func testRedactsHeadersCaseInsensitively() {
        let command = CurlLoggingMiddleware(redactedHeaders: ["authorization", "X-API-KEY"])
            .command(
                for: makeHead(headers: [
                    "Authorization": "Bearer secret", "x-api-key": "key", "Accept": "*/*",
                ]),
                body: .none
            )

        #expect(
            command
                == "curl -X GET 'https://api.example.com/items' -H 'Authorization: <redacted>' -H 'x-api-key: <redacted>' -H 'Accept: */*'"
        )
    }

    @Test(
        "CurlLoggingMiddlewareTests: Verifies the default redaction covers credentials and cookies"
    )
    func testDefaultRedaction() {
        let command = CurlLoggingMiddleware()
            .command(
                for: makeHead(
                    headers: ["Authorization": "a", "Cookie": "b", "Proxy-Authorization": "c"]
                ),
                body: .none
            )

        #expect(!command.contains(": a'"))
        #expect(!command.contains(": b'"))
        #expect(!command.contains(": c'"))
        #expect(command.components(separatedBy: "<redacted>").count == 4)
    }

    @Test("CurlLoggingMiddlewareTests: Verifies single quotes are escaped for the shell")
    func testEscapesSingleQuotes() {
        let command = CurlLoggingMiddleware()
            .command(
                for: makeHead(url: "https://api.example.com/it's", headers: ["X-Note": "don't"]),
                body: .bytes(ByteBuffer(string: #"{"name":"O'Brien"}"#))
            )

        #expect(
            command
                == #"curl -X GET 'https://api.example.com/it'\''s' -H 'X-Note: don'\''t' --data-binary '{"name":"O'\''Brien"}'"#
        )
    }

    @Test(
        "CurlLoggingMiddlewareTests: Verifies an in-memory body within the limit is shown in full"
    )
    func testRendersBytesBody() {
        let command = CurlLoggingMiddleware(maxBodyBytes: 4)
            .command(for: makeHead(method: .POST), body: .bytes(ByteBuffer(string: "abcd")))

        #expect(command == "curl -X POST 'https://api.example.com/items' --data-binary 'abcd'")
    }

    @Test("CurlLoggingMiddlewareTests: Verifies an in-memory body over the limit is truncated")
    func testTruncatesBytesBody() {
        let command = CurlLoggingMiddleware(maxBodyBytes: 4)
            .command(for: makeHead(method: .POST), body: .bytes(ByteBuffer(string: "abcdefgh")))

        #expect(
            command
                == "curl -X POST 'https://api.example.com/items' --data-binary 'abcd' # body truncated to 4 of 8 bytes"
        )
    }

    @Test("CurlLoggingMiddlewareTests: Verifies a negative body limit is treated as zero")
    func testNegativeLimitHidesBody() {
        let command = CurlLoggingMiddleware(maxBodyBytes: -1)
            .command(for: makeHead(method: .POST), body: .bytes(ByteBuffer(string: "ab")))

        #expect(
            command
                == "curl -X POST 'https://api.example.com/items' --data-binary '' # body truncated to 0 of 2 bytes"
        )
    }

    @Test("CurlLoggingMiddlewareTests: Verifies a file body is referenced by path")
    func testRendersFileBody() {
        let command = CurlLoggingMiddleware()
            .command(for: makeHead(method: .PUT), body: .file(path: "/tmp/my upload.bin"))

        #expect(
            command
                == "curl -X PUT 'https://api.example.com/items' --data-binary '@/tmp/my upload.bin'"
        )
    }

    @Test(
        "CurlLoggingMiddlewareTests: Verifies the multiline format puts each option on its own line"
    )
    func testMultilineFormat() {
        let command = CurlLoggingMiddleware(format: .multiline)
            .command(
                for: makeHead(method: .POST, headers: ["Accept": "*/*"]),
                body: .bytes(ByteBuffer(string: "ab"))
            )

        #expect(
            command == """
                curl -X POST 'https://api.example.com/items' \\
                  -H 'Accept: */*' \\
                  --data-binary 'ab'
                """
        )
    }

    @Test(
        "CurlLoggingMiddlewareTests: Verifies the truncation note stays on the last line in multiline format"
    )
    func testMultilineTruncationNoteIsLast() {
        let command = CurlLoggingMiddleware(format: .multiline, maxBodyBytes: 1)
            .command(
                for: makeHead(method: .POST, headers: ["Accept": "*/*"]),
                body: .bytes(ByteBuffer(string: "ab"))
            )

        #expect(
            command == """
                curl -X POST 'https://api.example.com/items' \\
                  -H 'Accept: */*' \\
                  --data-binary 'a' # body truncated to 1 of 2 bytes
                """
        )
    }

    @Test(
        "CurlLoggingMiddlewareTests: Verifies a multiline request without options stays on one line"
    )
    func testMultilineWithoutOptions() {
        let command = CurlLoggingMiddleware(format: .multiline)
            .command(for: makeHead(), body: .none)

        #expect(command == "curl -X GET 'https://api.example.com/items'")
    }

    @Test(
        "CurlLoggingMiddlewareTests: Verifies the command is logged at the configured level and the response passes through"
    )
    func testLogsAndPassesThrough() async throws {
        let records = NIOLockedValueBox<[(Logger.Level, String)]>([])
        var logger = Logger(label: "curl-test") { _ in CapturingLogHandler(records: records) }
        logger.logLevel = .trace
        let context = MiddlewareContext(attempt: 0, requestID: "abc", logger: logger, body: .none)

        let response = try await CurlLoggingMiddleware(level: .notice)
            .intercept(makeHead(), context: context) { _ in HTTPClientResponse(status: .created) }

        #expect(response.status == .created)
        #expect(records.withLockedValue { $0.map(\.0) } == [.notice])
        #expect(
            records.withLockedValue { $0.map(\.1) } == [
                "curl -X GET 'https://api.example.com/items'"
            ]
        )
    }

    @Test(
        "CurlLoggingMiddlewareTests: Verifies a request sent through the client is logged with its final headers"
    )
    func testLogsThroughClient() async throws {
        let records = NIOLockedValueBox<[(Logger.Level, String)]>([])
        var logger = Logger(label: "curl-test") { _ in CapturingLogHandler(records: records) }
        logger.logLevel = .debug

        let client = NetSkeinClient(
            transport: StaticTransport(),
            middlewares: [
                ClosureMiddleware { request, _, next in
                    var request = request
                    request.headers.replaceOrAdd(name: "Authorization", value: "Bearer secret")
                    return try await next(request)
                },
                CurlLoggingMiddleware(),
            ],
            logger: logger
        )

        _ = try await client.post("https://api.example.com/items").json(["a": 1]).send()

        let curl = records.withLockedValue { $0 }.map(\.1).filter { $0.hasPrefix("curl ") }
        #expect(curl.count == 1)
        #expect(curl.first?.contains("-H 'Authorization: <redacted>'") == true)
        #expect(curl.first?.contains(#"--data-binary '{"a":1}'"#) == true)
    }
}

// MARK: - Test Helpers

extension CurlLoggingMiddlewareTests {
    private func makeHead(
        method: HTTPMethod = .GET,
        url: String = "https://api.example.com/items",
        headers: HTTPHeaders = [:]
    ) -> RequestHead {
        RequestHead(method: method, url: url, headers: headers)
    }
}

private struct CapturingLogHandler: LogHandler {
    let records: NIOLockedValueBox<[(Logger.Level, String)]>
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        records.withLockedValue { $0.append((event.level, event.message.description)) }
    }
}

private final class StaticTransport: HTTPTransport {
    func execute(
        _ request: HTTPClientRequest,
        timeout: TimeAmount,
        logger: Logger?
    ) async throws -> HTTPClientResponse {
        HTTPClientResponse(status: .ok)
    }

    func shutdown() async throws {}
}
