import AsyncHTTPClient
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import Testing

@testable import NetSkein
@testable import NetSkeinTesting

struct RequestExecutorTests {
    struct MockStubOutageError: Error, CustomStringConvertible, Sendable {
        var description: String { "Simulated socket dropout." }
    }
}

// MARK: - Buffered Execution

extension RequestExecutorTests {
    @Test("RequestExecutorTests: Verifies buffered execution returns success response on 200 OK")
    func testBufferedExecutionSuccess() async throws {
        let expectedBuffer = ByteBuffer(string: "{\"status\":\"ok\"}")
        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/data",
            outcome: .response(
                status: .ok,
                headers: ["Content-Type": "application/json"],
                body: expectedBuffer
            )
        )
        let client = NetSkeinClient.testing().addStub(stub).build()
        let executor = makeExecutor(client: client, url: "https://api.example.com/data")

        let response = try await executor.send()

        #expect(response.status == .ok)
        #expect(response.headers.first(name: "Content-Type") == "application/json")
        #expect(response.text() == "{\"status\":\"ok\"}")
    }

    @Test(
        "RequestExecutorTests: Verifies cookie jar injects Cookie header and ingests valid Set-Cookie headers"
    )
    func testBufferedExecutionCookieHandling() async throws {
        let cookieJar = CookieJar()
        cookieJar.setCookie(host: "api.example.com", name: "session_id", value: "token_123")

        let isCookieSent = NIOLockedValueBox(false)

        var responseHeaders = HTTPHeaders()
        responseHeaders.add(name: "Set-Cookie", value: "user=octocat; Path=/; Secure")
        responseHeaders.add(name: "Set-Cookie", value: "malformed_cookie_no_equal_sign")

        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/profile",
            requestValidator: { request in
                if let cookie = request.headers.first(name: "Cookie") {
                    #expect(cookie.contains("session_id=token_123"))
                    isCookieSent.withLockedValue { $0 = true }
                }
            },
            outcome: .response(status: .ok, headers: responseHeaders, body: nil)
        )

        let client = NetSkeinClient.testing()
            .cookieJar(cookieJar)
            .addStub(stub)
            .build()

        let executor = makeExecutor(client: client, url: "https://api.example.com/profile")
        _ = try await executor.send()

        #expect(isCookieSent.withLockedValue { $0 } == true)
        #expect(cookieJar.cookieHeader(for: "api.example.com")?.contains("user=octocat") == true)
    }

    @Test(
        "RequestExecutorTests: Verifies retry loop recovers when transient 503 succeeds on next attempt"
    )
    func testBufferedExecutionRecoversViaRetry() async throws {
        let stubFail = HTTPStub(
            method: .GET,
            urlMatcher: { $0.contains("/retry-recover") },
            outcome: .response(status: .serviceUnavailable, headers: [:], body: nil)
        )
        let stubSuccess = HTTPStub(
            method: .GET,
            urlMatcher: { $0.contains("/retry-recover") },
            outcome: .response(status: .ok, headers: [:], body: ByteBuffer(string: "Recovered!"))
        )

        let client = NetSkeinClient.testing()
            .addStubs([stubFail, stubSuccess])
            .build()

        let executor = makeExecutor(
            client: client,
            url: "https://api.example.com/retry-recover",
            retryPolicy: .standard(maxRetries: 2, backoff: .immediate)
        )

        let response = try await executor.send()
        #expect(response.status == .ok)
        #expect(response.text() == "Recovered!")
    }

    @Test("RequestExecutorTests: Verifies retry loop exhausts retries and throws network failure")
    func testBufferedExecutionExhaustsRetries() async {
        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/fail",
            outcome: .error(MockStubOutageError())
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        let executor = makeExecutor(
            client: client,
            url: "https://api.example.com/fail",
            retryPolicy: .standard(maxRetries: 1, backoff: .immediate)
        )

        await #expect(throws: NetSkeinError.self) {
            _ = try await executor.send()
        }
    }

    @Test(
        "RequestExecutorTests: Verifies checkCancellation throws networkFailure when task is cancelled"
    )
    func testBufferedExecutionTaskCancellation() async throws {
        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/slow",
            delay: .milliseconds(500),
            outcome: .response(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()
        let executor = makeExecutor(client: client, url: "https://api.example.com/slow")

        let task = Task {
            try await executor.send()
        }
        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            Issue.record("Expected task to fail with cancellation error")
        case .failure(let error):
            let netError = try #require(error as? NetSkeinError)
            #expect(netError.kind == .networkFailure)
        }
    }

    @Test(
        "RequestExecutorTests: Verifies retry backoff overrides delay when Retry-After is larger than backoff"
    )
    func testRetryAfterOverridesSmallerBackoff() async throws {
        var headers = HTTPHeaders()
        headers.add(name: "Retry-After", value: "1")  // 1 second > 0 nanoseconds

        let stubFail = HTTPStub(
            method: .GET,
            urlMatcher: { $0.contains("/retry-after-override") },
            outcome: .response(status: .tooManyRequests, headers: headers, body: nil)
        )
        let stubSuccess = HTTPStub(
            method: .GET,
            urlMatcher: { $0.contains("/retry-after-override") },
            outcome: .response(status: .ok, headers: [:], body: ByteBuffer(string: "OK"))
        )

        let client = NetSkeinClient.testing().addStubs([stubFail, stubSuccess]).build()
        let policy = RetryPolicy(
            maxRetries: 1,
            backoff: .immediate,
            respectRetryAfterHeader: true
        ) { _ in true }

        let executor = makeExecutor(
            client: client,
            url: "https://api.example.com/retry-after-override",
            retryPolicy: policy
        )
        let response = try await executor.send()
        #expect(response.status == .ok)
    }

    @Test("RequestExecutorTests: Verifies sleepBetweenRetries throws when cancelled during sleep")
    func testSleepBetweenRetriesCancellation() async throws {
        let stubFail = HTTPStub(
            method: .GET,
            url: "https://api.example.com/sleep-cancel",
            outcome: .response(status: .serviceUnavailable, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stubFail).build()

        let policy = RetryPolicy(
            maxRetries: 2,
            backoff: .constant(.seconds(2)),  // Long sleep so we can cancel during sleep
            respectRetryAfterHeader: false
        ) { _ in true }

        let executor = makeExecutor(
            client: client,
            url: "https://api.example.com/sleep-cancel",
            retryPolicy: policy
        )

        let task = Task {
            try await executor.send()
        }

        // Give it time to fail attempt 0 and enter sleep
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            Issue.record("Expected task to fail with cancellation during sleep")
        case .failure(let error):
            let netError = try #require(error as? NetSkeinError)
            #expect(netError.kind == .networkFailure)
        }
    }

    @Test(
        "RequestExecutorTests: Verifies buffered execution throws captured error when maxRetries is exhausted"
    )
    func testBufferedExecutionExhaustsAndThrows() async {
        let stub = HTTPStub(
            method: .GET,
            urlMatcher: { $0.contains("/exhaust-test") },
            outcome: .error(MockStubOutageError())
        )
        let client = NetSkeinClient.testing().addStub(stub).build()
        let executor = makeExecutor(
            client: client,
            url: "https://api.example.com/exhaust-test",
            retryPolicy: .standard(maxRetries: 1, backoff: .immediate)
        )

        do {
            _ = try await executor.send()
            Issue.record("Expected execute() to throw after retries exhausted")
        } catch {
            #expect(error.kind == .networkFailure)
        }
    }
}

// MARK: - Streaming Execution

extension RequestExecutorTests {
    @Test(
        "RequestExecutorTests: Verifies streaming execution streams chunks and returns response head"
    )
    func testStreamingExecutionSuccess() async throws {
        let payload = ByteBuffer(string: "chunk1_chunk2")
        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/stream",
            outcome: .response(status: .ok, headers: ["Content-Length": "13"], body: payload)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()
        let executor = makeExecutor(client: client, url: "https://api.example.com/stream")

        let receivedBuffer = NIOLockedValueBox(ByteBuffer())
        let result = try await executor.stream { chunk, _, _ in
            _ = receivedBuffer.withLockedValue { $0.writeImmutableBuffer(chunk) }
        }

        #expect(result.status == .ok)
        #expect(result.headers.first(name: "Content-Length") == "13")
        #expect(receivedBuffer.withLockedValue { String(buffer: $0) } == "chunk1_chunk2")
    }

    @Test("RequestExecutorTests: Verifies streaming execution throws badStatus on non-2xx status")
    func testStreamingExecutionNon2xxThrows() async {
        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/stream-error",
            outcome: .response(status: .notFound, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()
        let executor = makeExecutor(
            client: client,
            url: "https://api.example.com/stream-error",
            retryPolicy: .disabled
        )

        await #expect(throws: NetSkeinError.self) {
            _ = try await executor.stream { _, _, _ in }
        }
    }

    @Test(
        "RequestExecutorTests: Verifies streaming execution wraps consumer callback errors as clientError"
    )
    func testStreamingExecutionCallbackError() async {
        struct MockConsumerError: Error {}

        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/stream-callback-error",
            outcome: .response(status: .ok, headers: [:], body: ByteBuffer(string: "data"))
        )
        let client = NetSkeinClient.testing().addStub(stub).build()
        let executor = makeExecutor(
            client: client,
            url: "https://api.example.com/stream-callback-error",
            retryPolicy: .disabled
        )

        do {
            _ = try await executor.stream { _, _, _ in
                throw MockConsumerError()
            }
            Issue.record("Expected consumer callback error to throw clientError")
        } catch {
            #expect(error.kind == .clientError)
        }
    }

    @Test("RequestExecutorTests: Verifies streaming execution retries on failure and succeeds")
    func testStreamingExecutionRecoversViaRetry() async throws {
        let stubFail = HTTPStub(
            method: .GET,
            urlMatcher: { $0.contains("/stream-retry") },
            outcome: .response(status: .serviceUnavailable, headers: [:], body: nil)
        )
        let stubSuccess = HTTPStub(
            method: .GET,
            urlMatcher: { $0.contains("/stream-retry") },
            outcome: .response(
                status: .ok,
                headers: ["Content-Length": "4"],
                body: ByteBuffer(string: "DATA")
            )
        )

        let client = NetSkeinClient.testing().addStubs([stubFail, stubSuccess]).build()
        let executor = makeExecutor(
            client: client,
            url: "https://api.example.com/stream-retry",
            retryPolicy: .standard(maxRetries: 1, backoff: .immediate)
        )

        let result = try await executor.stream { _, _, _ in }
        #expect(result.status == .ok)
    }
}

// MARK: - File Download Execution

extension RequestExecutorTests {
    @Test(
        "RequestExecutorTests: Verifies fresh file download writes content to disk and tracks progress"
    )
    func testDownloadExecutionFresh() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent("test_download_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destURL) }

        let downloadData = ByteBuffer(string: "Downloaded content for testing.")
        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/download-fresh",
            outcome: .response(status: .ok, headers: ["Content-Length": "31"], body: downloadData)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()
        let executor = makeExecutor(client: client, url: "https://api.example.com/download-fresh")

        let progressReported = NIOLockedValueBox(false)

        try await executor.download(
            to: destURL.path,
            resumption: .disabled,
            onProgress: { transferred, total in
                #expect(transferred == 31)
                #expect(total == 31)
                progressReported.withLockedValue { $0 = true }
            }
        )

        let writtenData = try Data(contentsOf: destURL)
        #expect(String(data: writtenData, encoding: .utf8) == "Downloaded content for testing.")
        #expect(progressReported.withLockedValue { $0 } == true)
    }

    @Test(
        "RequestExecutorTests: Verifies download resumption sends Range and appends on 206 Partial Content"
    )
    func testDownloadExecutionResumptionPartialContent() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent("test_resume_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destURL) }

        // Create a pre-existing 10-byte file on disk
        let initialData = Data("0123456789".utf8)
        try initialData.write(to: destURL)

        let isRangeValidated = NIOLockedValueBox(false)

        // Mock 206 Partial Content response
        let appendChunk = ByteBuffer(string: "ABCDE")
        var responseHeaders = HTTPHeaders()
        responseHeaders.add(name: "Content-Range", value: "bytes 10-14/15")
        responseHeaders.add(name: "ETag", value: "\"valid-etag\"")

        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/file.bin",
            requestValidator: { request in
                #expect(request.headers.first(name: "Range") == "bytes=10-")
                #expect(request.headers.first(name: "If-Range") == "\"initial-etag\"")
                isRangeValidated.withLockedValue { $0 = true }
            },
            outcome: .response(status: .partialContent, headers: responseHeaders, body: appendChunk)
        )

        let client = NetSkeinClient.testing().addStub(stub).build()
        let executor = makeExecutor(client: client, url: "https://api.example.com/file.bin")

        try await executor.download(
            to: destURL.path,
            resumption: .ifPossible(validator: "\"initial-etag\"")
        )

        #expect(isRangeValidated.withLockedValue { $0 } == true)

        let fullFileString = try String(contentsOf: destURL, encoding: .utf8)
        #expect(fullFileString == "0123456789ABCDE")
    }

    @Test(
        "RequestExecutorTests: Verifies download resumption resets and overwrites when server returns 200 OK"
    )
    func testDownloadExecutionResumptionFallbackTo200OK() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent("test_resume_200_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destURL) }

        // Existing file on disk
        try Data("OLD_DATA_TO_OVERWRITE".utf8).write(to: destURL)

        let replacementChunk = ByteBuffer(string: "NEW_FULL_FILE")
        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/file.bin",
            outcome: .response(
                status: .ok,
                headers: ["Content-Length": "13"],
                body: replacementChunk
            )
        )

        let client = NetSkeinClient.testing().addStub(stub).build()
        let executor = makeExecutor(client: client, url: "https://api.example.com/file.bin")

        try await executor.download(
            to: destURL.path,
            resumption: .ifPossible(validator: "\"etag\"")
        )

        let fullFileString = try String(contentsOf: destURL, encoding: .utf8)
        #expect(fullFileString == "NEW_FULL_FILE")
    }

    @Test(
        "RequestExecutorTests: Verifies download truncates file and throws when receiving 416 Range Not Satisfiable"
    )
    func testDownloadExecutionRangeNotSatisfiable() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent("test_416_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destURL) }

        try Data("SOME_INITIAL_DATA".utf8).write(to: destURL)

        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/range-fail",
            outcome: .response(status: .rangeNotSatisfiable, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()
        let executor = makeExecutor(
            client: client,
            url: "https://api.example.com/range-fail",
            retryPolicy: .disabled
        )

        await #expect(throws: NetSkeinError.self) {
            try await executor.download(
                to: destURL.path,
                resumption: .ifPossible()
            )
        }

        // File must be cleared to 0 bytes
        let remainingSize =
            try FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int64
        #expect(remainingSize == 0)
    }

    @Test(
        "RequestExecutorTests: Verifies download throws ioFailure when writing to an invalid filesystem path"
    )
    func testDownloadExecutionInvalidPathThrowsIOFailure() async {
        let impossiblePath = "/invalid_root_directory_netskein_test/output.bin"
        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/download-io-fail",
            outcome: .response(status: .ok, headers: [:], body: ByteBuffer(string: "data"))
        )
        let client = NetSkeinClient.testing().addStub(stub).build()
        let executor = makeExecutor(
            client: client,
            url: "https://api.example.com/download-io-fail",
            retryPolicy: .disabled
        )

        do {
            try await executor.download(to: impossiblePath)
            Issue.record("Expected download to throw .ioFailure for invalid path")
        } catch {
            #expect(error.kind == .ioFailure)
        }
    }

    @Test("RequestExecutorTests: Verifies retry backoff respects Retry-After header duration")
    func testSleepBetweenRetriesRespectsRetryAfterHeader() async throws {
        var failHeaders = HTTPHeaders()
        failHeaders.add(name: "Retry-After", value: "0")  // 0 seconds delta-seconds

        let stubFail = HTTPStub(
            method: .GET,
            urlMatcher: { $0.contains("/retry-after") },
            outcome: .response(status: .tooManyRequests, headers: failHeaders, body: nil)
        )
        let stubSuccess = HTTPStub(
            method: .GET,
            urlMatcher: { $0.contains("/retry-after") },
            outcome: .response(status: .ok, headers: [:], body: ByteBuffer(string: "OK"))
        )

        let client = NetSkeinClient.testing()
            .addStubs([stubFail, stubSuccess])
            .build()

        let policy = RetryPolicy(
            maxRetries: 1,
            backoff: .immediate,
            respectRetryAfterHeader: true
        ) { _ in true }

        let executor = makeExecutor(
            client: client,
            url: "https://api.example.com/retry-after",
            retryPolicy: policy
        )

        let response = try await executor.send()
        #expect(response.status == .ok)
    }

    @Test(
        "RequestExecutorTests: Verifies download throws ioFailure when 206 append fails due to read-only file"
    )
    func testDownloadAppendHandleFailure() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent(
            "test_readonly_append_\(UUID().uuidString).bin"
        )

        // Create file with 10 bytes so existingBytes > 0
        try Data("0123456789".utf8).write(to: destURL)

        // Lock file to read-only (0o444) so FileHandle(forWritingAtPath:) fails
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: destURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: destURL.path
            )
            try? FileManager.default.removeItem(at: destURL)
        }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Range", value: "bytes 10-14/15")
        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/file.bin",
            outcome: .response(
                status: .partialContent,
                headers: headers,
                body: ByteBuffer(string: "ABC")
            )
        )
        let client = NetSkeinClient.testing().addStub(stub).build()
        let executor = makeExecutor(
            client: client,
            url: "https://api.example.com/file.bin",
            retryPolicy: .disabled
        )

        do {
            try await executor.download(to: destURL.path, resumption: .ifPossible())
            Issue.record(
                "Expected download to throw .ioFailure when opening read-only file for append"
            )
        } catch {
            #expect(error.kind == .ioFailure)
        }
    }

    @Test(
        "RequestExecutorTests: Verifies pre-existing file is truncated on attempt 0 when resumption is disabled"
    )
    func testDownloadClearsPreExistingFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent("test_pre_existing_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destURL) }

        // Create file BEFORE calling execute
        try Data("OLD_FILE_BEFORE_RUN".utf8).write(to: destURL)

        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/fresh-replace",
            outcome: .response(
                status: .ok,
                headers: ["Content-Length": "3"],
                body: ByteBuffer(string: "NEW")
            )
        )
        let client = NetSkeinClient.testing().addStub(stub).build()
        let executor = makeExecutor(client: client, url: "https://api.example.com/fresh-replace")

        try await executor.download(to: destURL.path, resumption: .disabled)

        let resultData = try String(contentsOf: destURL, encoding: .utf8)
        #expect(resultData == "NEW")
    }

    @Test("RequestExecutorTests: Verifies Last-Modified header is captured when ETag is absent")
    func testDownloadCapturesLastModified() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent("test_last_mod_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destURL) }

        var headers = HTTPHeaders()
        headers.add(name: "Last-Modified", value: "Wed, 21 Oct 2026 07:28:00 GMT")

        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/file-with-date",
            outcome: .response(status: .ok, headers: headers, body: ByteBuffer(string: "payload"))
        )
        let client = NetSkeinClient.testing().addStub(stub).build()
        let executor = makeExecutor(client: client, url: "https://api.example.com/file-with-date")

        try await executor.download(to: destURL.path, resumption: .onRetry)
        #expect(FileManager.default.fileExists(atPath: destURL.path))
    }

    @Test("RequestExecutorTests: Verifies download throws badStatus on 500 Internal Server Error")
    func testDownloadThrowsOn500Status() async {
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent("test_500_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destURL) }

        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/download-500",
            outcome: .response(status: .internalServerError, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()
        let executor = makeExecutor(
            client: client,
            url: "https://api.example.com/download-500",
            retryPolicy: .disabled
        )

        await #expect(throws: NetSkeinError.self) {
            try await executor.download(to: destURL.path)
        }
    }

    @Test("RequestExecutorTests: Verifies download execution retries on failure and recovers")
    func testDownloadExecutionRecoversViaRetry() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent("test_download_retry_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destURL) }

        let stubFail = HTTPStub(
            method: .GET,
            urlMatcher: { $0.contains("/download-retry") },
            outcome: .response(status: .gatewayTimeout, headers: [:], body: nil)
        )
        let stubSuccess = HTTPStub(
            method: .GET,
            urlMatcher: { $0.contains("/download-retry") },
            outcome: .response(status: .ok, headers: [:], body: ByteBuffer(string: "SAVED"))
        )

        let client = NetSkeinClient.testing().addStubs([stubFail, stubSuccess]).build()
        let executor = makeExecutor(
            client: client,
            url: "https://api.example.com/download-retry",
            retryPolicy: .standard(maxRetries: 1, backoff: .immediate)
        )

        try await executor.download(to: destURL.path)
        let data = try String(contentsOf: destURL, encoding: .utf8)
        #expect(data == "SAVED")
    }

    @Test("RequestExecutorTests: Verifies download catches cancellation during body streaming")
    func testDownloadCancellationDuringStream() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent("test_stream_cancel_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destURL) }

        let taskBox = NIOLockedValueBox<Task<Void, any Error>?>(nil)

        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/cancel-download",
            requestValidator: { _ in
                // Cancel the task right after request validation, before body streaming begins
                taskBox.withLockedValue { $0?.cancel() }
            },
            outcome: .response(
                status: .ok,
                headers: [:],
                body: ByteBuffer(string: "stream_payload")
            )
        )
        let client = NetSkeinClient.testing().addStub(stub).build()
        let executor = makeExecutor(
            client: client,
            url: "https://api.example.com/cancel-download",
            retryPolicy: .disabled
        )

        let task = Task {
            try await executor.download(to: destURL.path)
        }
        taskBox.withLockedValue { $0 = task }

        let result = await task.result
        switch result {
        case .success:
            Issue.record("Expected download to fail with cancellation error")
        case .failure(let error):
            let netError = try #require(error as? NetSkeinError)
            #expect(netError.kind == .networkFailure)
        }
    }

    @Test(
        "RequestExecutorTests: Verifies 206 without Content-Range derives total from Content-Length plus existing bytes"
    )
    func testDownloadPartialContentFallsBackToContentLength() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent("test_resume_len_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destURL) }

        try Data("0123456789".utf8).write(to: destURL)

        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/file.bin",
            outcome: .response(
                status: .partialContent,
                headers: ["Content-Length": "5"],
                body: ByteBuffer(string: "ABCDE")
            )
        )
        let client = NetSkeinClient.testing().addStub(stub).build()
        let executor = makeExecutor(client: client, url: "https://api.example.com/file.bin")

        let reportedTotal = NIOLockedValueBox<Int64?>(nil)

        try await executor.download(
            to: destURL.path,
            resumption: .ifPossible(),
            onProgress: { _, total in
                reportedTotal.withLockedValue { $0 = total }
            }
        )

        #expect(reportedTotal.withLockedValue { $0 } == 15)
        #expect(try String(contentsOf: destURL, encoding: .utf8) == "0123456789ABCDE")
    }

    @Test("RequestExecutorTests: Verifies empty response body produces an empty file on disk")
    func testDownloadEmptyBodyCreatesEmptyFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent("test_empty_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destURL) }

        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/empty-file",
            outcome: .response(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()
        let executor = makeExecutor(client: client, url: "https://api.example.com/empty-file")

        try await executor.download(to: destURL.path)

        let size = try FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int64
        #expect(size == 0)
    }

    @Test(
        "RequestExecutorTests: Verifies body stream failure mid-download is wrapped as networkFailure"
    )
    func testDownloadBodyStreamFailureThrowsNetworkFailure() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent("test_stream_drop_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destURL) }

        let transport = StreamingHTTPClient(
            status: .ok,
            headers: [:],
            chunks: [ByteBuffer(string: "partial")],
            failure: MockStubOutageError()
        )
        let client = NetSkeinClient(
            transport: transport,
            logger: Logger(label: LoggerLabel.test)
        )
        let executor = makeExecutor(
            client: client,
            url: "https://api.example.com/stream-drop",
            retryPolicy: .disabled
        )

        do {
            try await executor.download(to: destURL.path)
            Issue.record("Expected download to throw .networkFailure when the body stream fails")
        } catch {
            #expect(error.kind == .networkFailure)
            #expect(error.errorDescription?.contains("Network connection dropped") == true)
        }
    }

    @Test(
        "RequestExecutorTests: Verifies filesystem error while seeking the download target is wrapped as ioFailure"
    )
    func testDownloadSeekFailureThrowsIOFailure() async throws {
        // A named pipe can be opened for writing but cannot be seeked, so seekToEnd() throws
        let fifo = try makeFIFOWithReader()
        defer {
            close(fifo.readerFD)
            unlink(fifo.path)
        }

        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/file.bin",
            outcome: .response(
                status: .partialContent,
                headers: [:],
                body: ByteBuffer(string: "AB")
            )
        )
        let client = NetSkeinClient.testing().addStub(stub).build()
        let executor = makeExecutor(
            client: client,
            url: "https://api.example.com/file.bin",
            retryPolicy: .disabled
        )

        do {
            try await executor.download(to: fifo.path, resumption: .ifPossible())
            Issue.record("Expected download to throw .ioFailure when the target cannot be seeked")
        } catch {
            #expect(error.kind == .ioFailure)
            #expect(error.errorDescription?.contains("preparing download target") == true)
        }
    }

    @Test(
        "RequestExecutorTests: Verifies disk write failure while streaming chunks is wrapped as ioFailure"
    )
    func testDownloadChunkWriteFailureThrowsIOFailure() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent("test_write_fail_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destURL) }

        let transport = StreamingHTTPClient(
            status: .ok,
            headers: [:],
            chunks: [ByteBuffer(string: "first"), ByteBuffer(string: "second")]
        )
        let client = NetSkeinClient(
            transport: transport,
            logger: Logger(label: LoggerLabel.test)
        )
        let executor = makeExecutor(
            client: client,
            url: "https://api.example.com/write-fail",
            retryPolicy: .disabled
        )

        do {
            // After the first chunk lands, revoke write access so the second chunk's write fails
            try await executor.download(
                to: destURL.path,
                onProgress: { _, _ in
                    revokeWriteAccess(toOpenFileAt: destURL.path)
                }
            )
            Issue.record("Expected download to throw .ioFailure when writing a chunk fails")
        } catch {
            #expect(error.kind == .ioFailure)
            #expect(error.errorDescription?.contains("Failed writing chunk") == true)
        }
    }
}

// MARK: - Middleware Execution

extension RequestExecutorTests {
    @Test(
        "RequestExecutorTests: Verifies middleware sees every retry attempt with its request ID and body"
    )
    func testMiddlewareContextPerAttempt() async throws {
        let stubFail = HTTPStub(
            method: .PUT,
            urlMatcher: { $0.contains("/middleware-context") },
            outcome: .response(status: .serviceUnavailable, headers: [:], body: nil)
        )
        let stubSuccess = HTTPStub(
            method: .PUT,
            urlMatcher: { $0.contains("/middleware-context") },
            outcome: .response(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStubs([stubFail, stubSuccess]).build()

        let seen = NIOLockedValueBox<
            [(attempt: Int, idMatches: Bool, body: RequestBodyDescription)]
        >([])
        let recorder = ClosureMiddleware { request, context, next in
            let idMatches = request.headers.first(name: "X-Request-ID") == context.requestID
            seen.withLockedValue { $0.append((context.attempt, idMatches, context.body)) }
            return try await next(request)
        }

        let executor = makeExecutor(
            client: client,
            method: .PUT,
            url: "https://api.example.com/middleware-context",
            body: .bytes(ByteBuffer(string: "payload")),
            retryPolicy: .standard(maxRetries: 1, backoff: .immediate),
            middlewares: [recorder]
        )

        let response = try await executor.send()

        let records = seen.withLockedValue { $0 }
        let expectedBody = RequestBodyDescription.bytes(ByteBuffer(string: "payload"))
        #expect(response.status == .ok)
        #expect(records.map(\.attempt) == [0, 1])
        #expect(records.map(\.idMatches) == [true, true])
        #expect(records.map(\.body) == [expectedBody, expectedBody])
    }

    @Test(
        "RequestExecutorTests: Verifies calling next twice re-sends a complete fresh file body"
    )
    func testMiddlewareResendGetsFreshBody() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_middleware_resend_\(UUID().uuidString).bin")
        try Data(repeating: 0x42, count: 100).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let transport = BodyDrainingTransport()
        let client = NetSkeinClient(transport: transport, logger: Logger(label: LoggerLabel.test))
        let resend = ClosureMiddleware { request, _, next in
            _ = try await next(request)
            return try await next(request)
        }

        let executor = makeExecutor(
            client: client,
            method: .PUT,
            url: "https://api.example.com/upload",
            body: .file(path: tempURL.path, chunkSize: 32, onProgress: nil),
            retryPolicy: .disabled,
            middlewares: [resend]
        )

        _ = try await executor.send()

        // A reused single-pass stream would deliver 100 bytes the first time and 0 the second
        #expect(transport.receivedBodySizes == [100, 100])
    }

    @Test(
        "RequestExecutorTests: Verifies a middleware failure is not retried as a network failure"
    )
    func testMiddlewareFailureIsNotRetried() async {
        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/middleware-failure",
            outcome: .response(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        let invocations = NIOLockedValueBox(0)
        let failing = ClosureMiddleware { _, _, _ in
            invocations.withLockedValue { $0 += 1 }
            throw MockStubOutageError()
        }

        let executor = makeExecutor(
            client: client,
            url: "https://api.example.com/middleware-failure",
            retryPolicy: .standard(maxRetries: 2, backoff: .immediate),
            middlewares: [failing]
        )

        do {
            _ = try await executor.send()
            Issue.record("Expected execute() to throw .middlewareFailure")
        } catch {
            #expect(error.kind == .middlewareFailure)
        }
        #expect(invocations.withLockedValue { $0 } == 1)
    }

    @Test("RequestExecutorTests: Verifies middleware applies to streaming and download requests")
    func testMiddlewareAppliesToStreamAndDownload() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_middleware_download_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let validatedRequests = NIOLockedValueBox(0)
        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/middleware-transfer",
            requestValidator: { request in
                #expect(request.headers.first(name: "X-Middleware") == "applied")
                validatedRequests.withLockedValue { $0 += 1 }
            },
            outcome: .response(status: .ok, headers: [:], body: ByteBuffer(string: "data"))
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        let addHeader = ClosureMiddleware { request, _, next in
            var request = request
            request.headers.replaceOrAdd(name: "X-Middleware", value: "applied")
            return try await next(request)
        }
        let executor = makeExecutor(
            client: client,
            url: "https://api.example.com/middleware-transfer",
            retryPolicy: .disabled,
            middlewares: [addHeader]
        )

        _ = try await executor.stream { _, _, _ in }
        try await executor.download(to: tempURL.path)

        #expect(validatedRequests.withLockedValue { $0 } == 2)
        #expect(try String(contentsOf: tempURL, encoding: .utf8) == "data")
    }
}

// MARK: - Test Factory Helpers

extension RequestExecutorTests {
    private func makeExecutor<Transport: HTTPTransport>(
        client: NetSkeinClient<Transport>,
        method: HTTPMethod = .GET,
        url: String,
        headers: HTTPHeaders = [:],
        body: BodySource = .none,
        timeout: TimeAmount? = nil,
        retryPolicy: RetryPolicy? = nil,
        maxResponseBytes: Int = 10 * 1024 * 1024,
        middlewares: [any HTTPMiddleware] = []
    ) -> RequestExecutor<Transport> {
        RequestExecutor(
            client: client,
            method: method,
            url: url,
            headers: headers,
            body: body,
            timeout: timeout,
            retryPolicy: retryPolicy,
            maxResponseBytes: maxResponseBytes,
            middlewares: middlewares
        )
    }

    /// Creates a named pipe with a non-blocking reader attached, so writers can open it without blocking.
    private func makeFIFOWithReader() throws -> (path: String, readerFD: Int32) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_fifo_\(UUID().uuidString)").path
        try #require(mkfifo(path, 0o644) == 0)
        let readerFD = open(path, O_RDONLY | O_NONBLOCK)
        try #require(readerFD >= 0)
        return (path, readerFD)
    }

    /// Swaps the process's open write descriptor for `path` with a read-only one, so the next write fails.
    private func revokeWriteAccess(toOpenFileAt path: String) {
        let targetPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))

        for fd in 0..<getdtablesize() where fcntl(fd, F_GETPATH, &buffer) != -1 {
            let openPath = String(
                decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            guard URL(fileURLWithPath: openPath).resolvingSymlinksInPath().path == targetPath
            else { continue }

            let readOnlyFD = open(path, O_RDONLY)
            dup2(readOnlyFD, fd)
            close(readOnlyFD)
        }
    }
}

// MARK: - Streaming Mock Client

/// Serves a fixed response whose body is streamed chunk by chunk, optionally failing after the last chunk.
private struct StreamingHTTPClient: HTTPTransport {
    let status: HTTPResponseStatus
    let headers: HTTPHeaders
    let chunks: [ByteBuffer]
    var failure: (any Error & Sendable)? = nil

    func execute(
        _ request: HTTPClientRequest,
        timeout: TimeAmount,
        logger: Logger?
    ) async throws -> HTTPClientResponse {
        let body = AsyncThrowingStream<ByteBuffer, any Error> { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish(throwing: failure)
        }
        return HTTPClientResponse(status: status, headers: headers, body: .stream(body))
    }

    func shutdown() async throws {}
}

// MARK: - Body Draining Transport

/// Reads every request body to the end, recording how many bytes each request carried.
private final class BodyDrainingTransport: HTTPTransport {
    private let bodySizes = NIOLockedValueBox<[Int]>([])

    var receivedBodySizes: [Int] { bodySizes.withLockedValue { $0 } }

    func execute(
        _ request: HTTPClientRequest,
        timeout: TimeAmount,
        logger: Logger?
    ) async throws -> HTTPClientResponse {
        var size = 0
        if let body = request.body {
            for try await chunk in body { size += chunk.readableBytes }
        }
        bodySizes.withLockedValue { $0.append(size) }
        return HTTPClientResponse(status: .ok)
    }

    func shutdown() async throws {}
}
