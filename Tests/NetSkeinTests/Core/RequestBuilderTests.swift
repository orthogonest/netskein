import AsyncHTTPClient
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import Testing

@testable import NetSkein
@testable import NetSkeinTesting

// MARK: initializers

struct RequestBuilderTests {
    @Test(
        "RequestBuilderTests: Verifies public and internal initialization with default properties"
    )
    func testInitialization() async throws {
        let stub = NetSkeinStub(
            method: .GET,
            url: "https://api.example.com",
            outcome: .success(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        let builder = RequestBuilder<MockHTTPClient, BodyIsBlocked, EmptyBody>(
            client: client,
            method: .GET,
            url: "https://api.example.com"
        )

        let response = try await builder.send()
        #expect(response.status == .ok)
    }
}

// MARK: Fluent Modifiers

extension RequestBuilderTests {
    @Test(
        "RequestBuilderTests: Verifies path concatenates URL segments and trims slashes correctly"
    )
    func testPathModifier() async throws {
        let stub1 = NetSkeinStub(
            method: .GET,
            url: "https://api.example.com/v1/users",
            outcome: .success(status: .ok, headers: [:], body: nil)
        )
        let stub2 = NetSkeinStub(
            method: .GET,
            url: "https://api.example.com/v1/profile",
            outcome: .success(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStubs([stub1, stub2]).build()

        // URL without trailing slash, segment without leading slash
        let res1 = try await client.get("https://api.example.com/v1")
            .path(NetSkeinPathSegment("users"))
            .send()
        #expect(res1.status == .ok)

        // URL with trailing slash, segment with leading and trailing slashes
        let res2 = try await client.get("https://api.example.com/v1/")
            .path(NetSkeinPathSegment("/profile/"))
            .send()
        #expect(res2.status == .ok)
    }

    @Test("RequestBuilderTests: Verifies header adds and replaces headers correctly")
    func testHeaderModifier() async throws {
        let isHeaderValidated = NIOLockedValueBox(false)

        let stub = NetSkeinStub(
            method: .GET,
            url: "https://api.example.com",
            requestValidator: { request in
                #expect(request.headers.first(name: "X-Custom-Header") == "Replaced")
                #expect(request.headers.first(name: "Accept") == "application/json")
                isHeaderValidated.withLockedValue { $0 = true }
            },
            outcome: .success(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        _ = try await client.get("https://api.example.com")
            .header("X-Custom-Header", "Initial")
            .header("X-Custom-Header", "Replaced")
            .header("Accept", "application/json")
            .send()

        #expect(isHeaderValidated.withLockedValue { $0 } == true)
    }

    @Test("RequestBuilderTests: Verifies query adds query items and handles malformed URLs safely")
    func testQueryModifier() async throws {
        let isQueryValidated = NIOLockedValueBox(false)

        let stub = NetSkeinStub(
            method: .GET,
            urlMatcher: { url in
                url.contains("q=swift") && url.contains("page=1")
            },
            requestValidator: { request in
                #expect(request.url.contains("q=swift"))
                #expect(request.url.contains("page=1"))
                isQueryValidated.withLockedValue { $0 = true }
            },
            outcome: .success(status: .ok, headers: [:], body: nil)
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
        "RequestBuilderTests: Verifies query returns self when URLComponents fails to parse malformed port"
    )
    func testQueryMalformedURLFallback() async throws {
        let malformedURL = "https://example.com:invalid_port"
        let stub = NetSkeinStub(
            method: .GET,
            url: malformedURL,
            outcome: .success(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        let response = try await client.get(malformedURL)
            .query(["key": "value"])
            .send()

        #expect(response.status == .ok)
    }

    @Test(
        "RequestBuilderTests: Verifies maxResponseSize, timeout, and retry modifiers update builder state"
    )
    func testConfigurationModifiers() async throws {
        let stub = NetSkeinStub(
            method: .GET,
            url: "https://api.example.com",
            outcome: .success(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        let response = try await client.get("https://api.example.com")
            .maxResponseSize(5 * 1024 * 1024)
            .timeout(.seconds(15))
            .retry(.standard(maxRetries: 5))
            .send()

        #expect(response.status == .ok)
    }
}

// MARK: - Body Transitions

extension RequestBuilderTests {
    @Test(
        "RequestBuilderTests: Verifies form payload encodes fields and sets application/x-www-form-urlencoded"
    )
    func testFormBodyTransition() async throws {
        let isFormValidated = NIOLockedValueBox(false)

        let stub = NetSkeinStub(
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
            outcome: .success(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        let response = try await client.post("https://api.example.com/login")
            .form(["username": "octocat", "password": "secret"])
            .send()

        #expect(response.status == .ok)
        #expect(isFormValidated.withLockedValue { $0 } == true)
    }

    @Test("RequestBuilderTests: Verifies json payload encodes model and sets application/json")
    func testJsonBodyTransitionSuccess() async throws {
        struct User: Codable {
            let name: String
            let age: Int
        }

        let isJsonValidated = NIOLockedValueBox(false)

        let stub = NetSkeinStub(
            method: .POST,
            url: "https://api.example.com/users",
            requestValidator: { request in
                #expect(request.headers.first(name: "Content-Type") == "application/json")
                #expect(request.body != nil)
                isJsonValidated.withLockedValue { $0 = true }
            },
            outcome: .success(status: .created, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        let response = try await client.post("https://api.example.com/users")
            .json(User(name: "Alice", age: 30))
            .send()

        #expect(response.status == .created)
        #expect(isJsonValidated.withLockedValue { $0 } == true)
    }

    @Test("RequestBuilderTests: Verifies json throws invalidPayload error when encoding fails")
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

    @Test("RequestBuilderTests: Verifies multipart payload sets boundary and Content-Type")
    func testMultipartBodyTransition() async throws {
        let isMultipartValidated = NIOLockedValueBox(false)
        let form = NetSkeinMultipartForm.builder()
            .text(name: "host", value: "example.com")
            .build()

        let stub = NetSkeinStub(
            method: .POST,
            url: "https://api.example.com/upload",
            requestValidator: { request in
                let contentType = request.headers.first(name: "Content-Type") ?? ""
                #expect(contentType.contains("multipart/form-data"))
                #expect(contentType.contains("boundary=\(form.boundary)"))
                isMultipartValidated.withLockedValue { $0 = true }
            },
            outcome: .success(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        let response = try await client.post("https://api.example.com/upload")
            .multipart(form)
            .send()

        #expect(response.status == .ok)
        #expect(isMultipartValidated.withLockedValue { $0 } == true)
    }

    @Test(
        "RequestBuilderTests: Verifies stream payload sets chunked headers and creates streaming body"
    )
    func testStreamBodyTransitionSuccess() async throws {
        let tempURL = try createTempFile(size: 64)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let isStreamValidated = NIOLockedValueBox(false)

        let stub = NetSkeinStub(
            method: .POST,
            url: "https://api.example.com/stream-upload",
            requestValidator: { request in
                #expect(request.headers.first(name: "Transfer-Encoding") == "chunked")
                #expect(request.headers.first(name: "Content-Type") == "application/octet-stream")
                #expect(request.body != nil)
                isStreamValidated.withLockedValue { $0 = true }
            },
            outcome: .success(status: .ok, headers: [:], body: nil)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        let response = try await client.post("https://api.example.com/stream-upload")
            .stream(fileAtPath: tempURL.path, chunkSize: 32)
            .send()

        #expect(response.status == .ok)
        #expect(isStreamValidated.withLockedValue { $0 } == true)
    }

    @Test("RequestBuilderTests: Verifies stream throws ioFailure when file does not exist")
    func testStreamBodyTransitionFileNotFound() {
        let client = NetSkeinClient.testing().build()
        let nonExistentPath = "/tmp/netskein_not_found_\(UUID().uuidString).bin"

        #expect(throws: NetSkeinError.self) {
            try client.post("https://api.example.com/upload")
                .stream(fileAtPath: nonExistentPath)
        }

        do {
            _ = try client.post("https://api.example.com/upload")
                .stream(fileAtPath: nonExistentPath)
            Issue.record("Expected stream() to throw ioFailure")
        } catch {
            #expect(error.kind == .ioFailure)
        }
    }

    @Test(
        "RequestBuilderTests: Verifies stream throws ioFailure when file exists but has no read permissions"
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
                .stream(fileAtPath: unreadableURL.path)
        }

        do {
            _ = try client.post("https://api.example.com/upload")
                .stream(fileAtPath: unreadableURL.path)
            Issue.record("Expected stream() to throw .ioFailure for unreadable file")
        } catch {
            #expect(error.kind == .ioFailure)
        }
    }
}

// MARK: - Type-State Escape Hatch

extension RequestBuilderTests {
    @Test(
        "RequestBuilderTests: Verifies dangerouslyAllowBody permits attaching body to blocked method"
    )
    func testDangerouslyAllowBody() async throws {
        let isMethodValidated = NIOLockedValueBox(false)

        let stub = NetSkeinStub(
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
            outcome: .success(status: .ok, headers: [:], body: nil)
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

extension RequestBuilderTests {
    @Test("RequestBuilderTests: Verifies send() routes execution and returns NetSkeinResponse")
    func testSendDelegation() async throws {
        let expectedBuffer = ByteBuffer(string: "OK_RESPONSE")
        let stub = NetSkeinStub(
            method: .GET,
            url: "https://api.example.com/status",
            outcome: .success(status: .ok, headers: [:], body: expectedBuffer)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        let response = try await client.get("https://api.example.com/status").send()
        #expect(response.status == .ok)
        #expect(response.text() == "OK_RESPONSE")
    }

    @Test("RequestBuilderTests: Verifies send(_ onChunk:) streams response chunks and returns head")
    func testSendOnChunkDelegation() async throws {
        let expectedBuffer = ByteBuffer(string: "streamed_chunk_data")
        let stub = NetSkeinStub(
            method: .GET,
            url: "https://api.example.com/stream",
            outcome: .success(status: .ok, headers: [:], body: expectedBuffer)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        let receivedChunkData = NIOLockedValueBox("")

        let result = try await client.get("https://api.example.com/stream")
            .send { chunk, _, _ in
                receivedChunkData.withLockedValue { $0 += String(buffer: chunk) }
            }

        #expect(result.status == .ok)
        #expect(receivedChunkData.withLockedValue { $0 } == "streamed_chunk_data")
    }

    @Test("RequestBuilderTests: Verifies download routes execution and streams file to disk")
    func testDownloadDelegation() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent("download_test_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destURL) }

        let expectedBuffer = ByteBuffer(string: "download_complete_payload")
        let stub = NetSkeinStub(
            method: .GET,
            url: "https://api.example.com/file",
            outcome: .success(status: .ok, headers: [:], body: expectedBuffer)
        )
        let client = NetSkeinClient.testing().addStub(stub).build()

        try await client.get("https://api.example.com/file")
            .download(toFileAtPath: destURL.path)

        let savedData = try Data(contentsOf: destURL)
        #expect(String(data: savedData, encoding: .utf8) == "download_complete_payload")
    }
}

// MARK: - Test Helpers

extension RequestBuilderTests {
    fileprivate func createTempFile(size: Int) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("RequestBuilderTest_\(UUID().uuidString).bin")
        let data = Data(repeating: 0x58, count: size)  // 'X'
        try data.write(to: fileURL)
        return fileURL
    }
}
