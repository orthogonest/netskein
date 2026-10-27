import AsyncHTTPClient
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import Testing

@testable import NetSkein
@testable import NetSkeinTesting

// MARK: initializers

struct NetSkeinRequestTests {
    @Test(
        "NetSkeinRequestTests: Verifies public and internal initialization with default properties"
    )
    func testInitialization() async throws {
        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com",
            outcome: .response(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        let builder = NetSkeinRequest<MockHTTPClient, BodyForbidden>(
            client: client,
            method: .GET,
            url: "https://api.example.com"
        )

        let response = try await builder.send()
        #expect(response.status == .ok)
    }
}

// MARK: Fluent Modifiers

extension NetSkeinRequestTests {
    @Test(
        "NetSkeinRequestTests: Verifies path concatenates URL segments and trims slashes correctly"
    )
    func testPathModifier() async throws {
        let stub1 = HTTPStub(
            method: .GET,
            url: "https://api.example.com/v1/users",
            outcome: .response(status: .ok, headers: [:], body: nil)
        )
        let stub2 = HTTPStub(
            method: .GET,
            url: "https://api.example.com/v1/profile",
            outcome: .response(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStubs([stub1, stub2]).build()

        // URL without trailing slash, segment without leading slash
        let res1 = try await client.get("https://api.example.com/v1")
            .path(PathSegment("users"))
            .send()
        #expect(res1.status == .ok)

        // URL with trailing slash, segment with leading and trailing slashes
        let res2 = try await client.get("https://api.example.com/v1/")
            .path(PathSegment("/profile/"))
            .send()
        #expect(res2.status == .ok)
    }

    @Test("NetSkeinRequestTests: Verifies header adds and replaces headers correctly")
    func testHeaderModifier() async throws {
        let isHeaderValidated = NIOLockedValueBox(false)

        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com",
            requestValidator: { request in
                #expect(request.headers.first(name: "X-Custom-Header") == "Replaced")
                #expect(request.headers.first(name: "Accept") == "application/json")
                isHeaderValidated.withLockedValue { $0 = true }
            },
            outcome: .response(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        _ = try await client.get("https://api.example.com")
            .header("X-Custom-Header", "Initial")
            .header("X-Custom-Header", "Replaced")
            .header("Accept", "application/json")
            .send()

        #expect(isHeaderValidated.withLockedValue { $0 } == true)
    }

    @Test("NetSkeinRequestTests: Verifies query adds query items and handles malformed URLs safely")
    func testQueryModifier() async throws {
        let isQueryValidated = NIOLockedValueBox(false)

        let stub = HTTPStub(
            method: .GET,
            urlMatcher: { url in
                url.contains("q=swift") && url.contains("page=1")
            },
            requestValidator: { request in
                #expect(request.url.contains("q=swift"))
                #expect(request.url.contains("page=1"))
                isQueryValidated.withLockedValue { $0 = true }
            },
            outcome: .response(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        // Valid URL with query items
        let response = try await client.get("https://api.example.com/search")
            .query(["q": "swift", "page": "1"])
            .send()
        #expect(response.status == .ok)
        #expect(isQueryValidated.withLockedValue { $0 } == true)

        // Malformed URL fallback (URLComponents fails -> returns self unmodified)
        let malformedBuilder = client.get("://invalid-url").query(["key": "value"])
        _ = malformedBuilder
    }

    @Test(
        "NetSkeinRequestTests: Verifies query returns self when URLComponents fails to parse malformed port"
    )
    func testQueryMalformedURLFallback() async throws {
        let malformedURL = "https://example.com:invalid_port"
        let stub = HTTPStub(
            method: .GET,
            url: malformedURL,
            outcome: .response(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        let response = try await client.get(malformedURL)
            .query(["key": "value"])
            .send()

        #expect(response.status == .ok)
    }

    @Test(
        "NetSkeinRequestTests: Verifies maxResponseBytes, timeout, and retry modifiers update builder state"
    )
    func testConfigurationModifiers() async throws {
        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com",
            outcome: .response(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        let response = try await client.get("https://api.example.com")
            .maxResponseBytes(5 * 1024 * 1024)
            .timeout(.seconds(15))
            .retry(.standard(maxRetries: 5))
            .send()

        #expect(response.status == .ok)
    }
}

// MARK: - Body Transitions

extension NetSkeinRequestTests {
    @Test(
        "NetSkeinRequestTests: Verifies form payload encodes fields and sets application/x-www-form-urlencoded"
    )
    func testFormBodyTransition() async throws {
        let isFormValidated = NIOLockedValueBox(false)

        let stub = HTTPStub(
            method: .POST,
            url: "https://api.example.com/login",
            requestValidator: { request in
                #expect(
                    request.headers.first(name: "Content-Type")
                        == "application/x-www-form-urlencoded"
                )
                #expect(request.body != nil)
                isFormValidated.withLockedValue { $0 = true }
            },
            outcome: .response(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        let response = try await client.post("https://api.example.com/login")
            .form(["username": "octocat", "password": "secret"])
            .send()

        #expect(response.status == .ok)
        #expect(isFormValidated.withLockedValue { $0 } == true)
    }

    @Test("NetSkeinRequestTests: Verifies json payload encodes model and sets application/json")
    func testJsonBodyTransitionSuccess() async throws {
        struct User: Codable {
            let name: String
            let age: Int
        }

        let isJsonValidated = NIOLockedValueBox(false)

        let stub = HTTPStub(
            method: .POST,
            url: "https://api.example.com/users",
            requestValidator: { request in
                #expect(request.headers.first(name: "Content-Type") == "application/json")
                #expect(request.body != nil)
                isJsonValidated.withLockedValue { $0 = true }
            },
            outcome: .response(status: .created, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        let response = try await client.post("https://api.example.com/users")
            .json(User(name: "Alice", age: 30))
            .send()

        #expect(response.status == .created)
        #expect(isJsonValidated.withLockedValue { $0 } == true)
    }

    @Test("NetSkeinRequestTests: Verifies json throws invalidPayload error when encoding fails")
    func testJsonBodyTransitionFailure() {
        struct FailingModel: Encodable {
            func encode(to encoder: Encoder) throws {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "Simulated encoding error")
                )
            }
        }

        let client = NetSkeinClient.testing().build()

        #expect(throws: NetSkeinError.self) {
            try client.post("https://api.example.com/users")
                .json(FailingModel())
        }

        do {
            _ = try client.post("https://api.example.com/users").json(FailingModel())
            Issue.record("Expected json() to throw invalidPayload")
        } catch {
            #expect(error.kind == .invalidPayload)
        }
    }

    @Test("NetSkeinRequestTests: Verifies multipart payload sets boundary and Content-Type")
    func testMultipartBodyTransition() async throws {
        let isMultipartValidated = NIOLockedValueBox(false)
        let form = MultipartForm.builder()
            .text(name: "host", value: "example.com")
            .build()

        let stub = HTTPStub(
            method: .POST,
            url: "https://api.example.com/upload",
            requestValidator: { request in
                let contentType = request.headers.first(name: "Content-Type") ?? ""
                #expect(contentType.contains("multipart/form-data"))
                #expect(contentType.contains("boundary=\(form.boundary)"))
                isMultipartValidated.withLockedValue { $0 = true }
            },
            outcome: .response(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        let response = try await client.post("https://api.example.com/upload")
            .multipart(form)
            .send()

        #expect(response.status == .ok)
        #expect(isMultipartValidated.withLockedValue { $0 } == true)
    }

    @Test(
        "NetSkeinRequestTests: Verifies file payload sets octet-stream content type and leaves framing to the transport"
    )
    func testFileBodyTransitionSuccess() async throws {
        let tempURL = try createTempFile(size: 64)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let isStreamValidated = NIOLockedValueBox(false)

        let stub = HTTPStub(
            method: .POST,
            url: "https://api.example.com/stream-upload",
            requestValidator: { request in
                #expect(request.headers.first(name: "Content-Type") == "application/octet-stream")
                #expect(request.body != nil)
                isStreamValidated.withLockedValue { $0 = true }
            },
            outcome: .response(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        let response = try await client.post("https://api.example.com/stream-upload")
            .file(atPath: tempURL.path, chunkSize: 32)
            .send()

        #expect(response.status == .ok)
        #expect(isStreamValidated.withLockedValue { $0 } == true)
    }

    @Test("NetSkeinRequestTests: Verifies stream throws ioFailure when file does not exist")
    func testStreamBodyTransitionFileNotFound() {
        let client = NetSkeinClient.testing().build()
        let nonExistentPath = "/tmp/netskein_not_found_\(UUID().uuidString).bin"

        #expect(throws: NetSkeinError.self) {
            try client.post("https://api.example.com/upload")
                .file(atPath: nonExistentPath)
        }

        do {
            _ = try client.post("https://api.example.com/upload")
                .file(atPath: nonExistentPath)
            Issue.record("Expected stream() to throw ioFailure")
        } catch {
            #expect(error.kind == .ioFailure)
        }
    }

    @Test(
        "NetSkeinRequestTests: Verifies stream throws ioFailure when file exists but has no read permissions"
    )
    func testStreamUnreadableFileThrowsIOFailure() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let unreadableURL = tempDir.appendingPathComponent("unreadable_\(UUID().uuidString).bin")

        // Create file with 16 bytes so attributesOfItem succeeds
        try Data(repeating: 0x55, count: 16).write(to: unreadableURL)

        // Remove read permissions (write-only: 0o200)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o200],
            ofItemAtPath: unreadableURL.path
        )

        defer {
            // Restore permissions so cleanup succeeds
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: unreadableURL.path
            )
            try? FileManager.default.removeItem(at: unreadableURL)
        }

        let client = NetSkeinClient.testing().build()

        #expect(throws: NetSkeinError.self) {
            try client.post("https://api.example.com/upload")
                .file(atPath: unreadableURL.path)
        }

        do {
            _ = try client.post("https://api.example.com/upload")
                .file(atPath: unreadableURL.path)
            Issue.record("Expected stream() to throw .ioFailure for unreadable file")
        } catch {
            #expect(error.kind == .ioFailure)
        }
    }

    @Test("NetSkeinRequestTests: Verifies file accepts a symlink to a regular file")
    func testFileBodyAcceptsSymlink() throws {
        let targetURL = try createTempFile(size: 64)
        let linkURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent("upload_link_\(UUID().uuidString).bin")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        defer {
            try? FileManager.default.removeItem(at: linkURL)
            try? FileManager.default.removeItem(at: targetURL)
        }

        let client = NetSkeinClient.testing().build()

        #expect(throws: Never.self) {
            try client.post("https://api.example.com/upload").file(atPath: linkURL.path)
        }
    }

    @Test("NetSkeinRequestTests: Verifies file throws ioFailure when the path is a directory")
    func testFileBodyRejectsDirectory() {
        let client = NetSkeinClient.testing().build()

        do {
            _ = try client.post("https://api.example.com/upload")
                .file(atPath: FileManager.default.temporaryDirectory.path)
            Issue.record("Expected file(atPath:) to throw .ioFailure for a directory")
        } catch {
            #expect(error.kind == .ioFailure)
            #expect(error.errorDescription?.contains("No regular file exists") == true)
        }
    }

    @Test("NetSkeinRequestTests: Verifies file rejects a named pipe instead of blocking on open")
    func testFileBodyRejectsFIFO() throws {
        let fifoPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload_fifo_\(UUID().uuidString)").path
        try #require(mkfifo(fifoPath, 0o644) == 0)
        defer { unlink(fifoPath) }

        try expectNoRegularFile(atPath: fifoPath)
    }

    @Test("NetSkeinRequestTests: Verifies file rejects a character device")
    func testFileBodyRejectsDevice() throws {
        try expectNoRegularFile(atPath: "/dev/null")
    }

    @Test("NetSkeinRequestTests: Verifies file rejects a symlink whose target does not exist")
    func testFileBodyRejectsBrokenSymlink() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let linkURL = tempDir.appendingPathComponent("broken_link_\(UUID().uuidString).bin")
        let missingTarget = tempDir.appendingPathComponent("missing_\(UUID().uuidString).bin")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: missingTarget)
        defer { try? FileManager.default.removeItem(at: linkURL) }

        try expectNoRegularFile(atPath: linkURL.path)
    }

    private func expectNoRegularFile(atPath path: String) throws {
        let client = NetSkeinClient.testing().build()

        do {
            _ = try client.post("https://api.example.com/upload").file(atPath: path)
            Issue.record("Expected file(atPath:) to throw .ioFailure for \(path)")
        } catch {
            #expect(error.kind == .ioFailure)
            #expect(error.errorDescription?.contains("No regular file exists") == true)
        }
    }
}

// MARK: - Type-State Escape Hatch

extension NetSkeinRequestTests {
    @Test(
        "NetSkeinRequestTests: Verifies dangerouslyAllowBody permits attaching body to blocked method"
    )
    func testDangerouslyAllowBody() async throws {
        let isMethodValidated = NIOLockedValueBox(false)

        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/query-with-body",
            requestValidator: { request in
                #expect(request.method == .GET)
                #expect(
                    request.headers.first(name: "Content-Type")
                        == "application/x-www-form-urlencoded"
                )
                isMethodValidated.withLockedValue { $0 = true }
            },
            outcome: .response(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        let response = try await client.get("https://api.example.com/query-with-body")
            .dangerouslyAllowBody()
            .form(["filter": "active"])
            .send()

        #expect(response.status == .ok)
        #expect(isMethodValidated.withLockedValue { $0 } == true)
    }
}

// MARK: - Execution Delegations

extension NetSkeinRequestTests {
    @Test("NetSkeinRequestTests: Verifies send() routes execution and returns NetSkeinResponse")
    func testSendDelegation() async throws {
        let expectedBuffer = ByteBuffer(string: "OK_RESPONSE")
        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/status",
            outcome: .response(status: .ok, headers: [:], body: expectedBuffer)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        let response = try await client.get("https://api.example.com/status").send()
        #expect(response.status == .ok)
        #expect(response.text() == "OK_RESPONSE")
    }

    @Test(
        "NetSkeinRequestTests: Verifies send(_ onChunk:) streams response chunks and returns head"
    )
    func testSendOnChunkDelegation() async throws {
        let expectedBuffer = ByteBuffer(string: "streamed_chunk_data")
        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/stream",
            outcome: .response(status: .ok, headers: [:], body: expectedBuffer)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        let receivedChunkData = NIOLockedValueBox("")

        let result = try await client.get("https://api.example.com/stream")
            .stream { chunk, _, _ in
                receivedChunkData.withLockedValue { $0 += String(buffer: chunk) }
            }

        #expect(result.status == .ok)
        #expect(receivedChunkData.withLockedValue { $0 } == "streamed_chunk_data")
    }

    @Test("NetSkeinRequestTests: Verifies download routes execution and streams file to disk")
    func testDownloadDelegation() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent("download_test_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destURL) }

        let expectedBuffer = ByteBuffer(string: "download_complete_payload")
        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/file",
            outcome: .response(status: .ok, headers: [:], body: expectedBuffer)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        try await client.get("https://api.example.com/file")
            .download(toFileAtPath: destURL.path)

        let savedData = try Data(contentsOf: destURL)
        #expect(String(data: savedData, encoding: .utf8) == "download_complete_payload")
    }
}

// MARK: - Middleware

extension NetSkeinRequestTests {
    @Test(
        "NetSkeinRequestTests: Verifies client middleware wraps request middleware, which runs in order"
    )
    func testMiddlewareOrdering() async throws {
        let events = NIOLockedValueBox<[String]>([])
        let stub = HTTPStub(
            method: .GET,
            url: "https://api.example.com/ordered",
            requestValidator: { _ in events.withLockedValue { $0.append("transport") } },
            outcome: .response(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing()
            .addStub(stub)
            .using(EventMiddleware(name: "client", events: events))
            .build()

        _ = try await client.get("https://api.example.com/ordered")
            .using(EventMiddleware(name: "request-1", events: events))
            .using { request, _, next in
                events.withLockedValue { $0.append("request-2") }
                return try await next(request)
            }
            .send()

        #expect(events.withLockedValue { $0 } == ["client", "request-1", "request-2", "transport"])
    }

    @Test("NetSkeinRequestTests: Verifies request middleware survives a body transition")
    func testMiddlewareSurvivesBodyTransition() async throws {
        let stub = HTTPStub(
            method: .POST,
            url: "https://api.example.com/with-body",
            requestValidator: { request in
                #expect(request.headers.first(name: "X-Signed") == "true")
            },
            outcome: .response(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        let response = try await client.post("https://api.example.com/with-body")
            .using { request, _, next in
                var request = request
                request.headers.replaceOrAdd(name: "X-Signed", value: "true")
                return try await next(request)
            }
            .json(["name": "report"])
            .send()

        #expect(response.status == .ok)
    }
}

private struct EventMiddleware: HTTPMiddleware {
    let name: String
    let events: NIOLockedValueBox<[String]>

    func intercept(
        _ request: RequestHead,
        context: MiddlewareContext,
        next: Next
    ) async throws -> HTTPClientResponse {
        events.withLockedValue { $0.append(name) }
        return try await next(request)
    }
}

// MARK: - Test Helpers

extension NetSkeinRequestTests {
    private func createTempFile(size: Int) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("NetSkeinRequestTest_\(UUID().uuidString).bin")
        let data = Data(repeating: 0x58, count: size)  // 'X'
        try data.write(to: fileURL)
        return fileURL
    }
}
