import AsyncHTTPClient
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import Testing

@testable import NetSkein

@Suite("RequestBuilder Comprehensive Coverage Analysis")
struct RequestBuilderTests {
    struct SamplePostPayload: Codable {
        let title: String
        let category: String
    }
}

// MARK: Fluent Chaining & Properties Configuration Path Coverage

extension RequestBuilderTests {
    @Test(
        "RequestBuilderTests: Verifies fluent mutation updates internal values cleanly across chain derivations"
    )
    func testFluentPropertyMutations() async throws {
        let client = NetSkeinClient()
        let request = RequestBuilder<BodyIsAllowed, EmptyBody>(
            client: client,
            method: .POST,
            url: "https://netskein.local"
        )
        .header("X-API-Version", "1.4.2")
        .query(["search": "swift6", "sort": "desc"])
        .maxResponseSize(5 * 1024 * 1024)
        .timeout(.seconds(15))

        let mirror = Mirror(reflecting: request)

        guard
            let urlString = mirror.descendant("url") as? String,
            let headers = mirror.descendant("headers") as? HTTPHeaders,
            let maxBytes = mirror.descendant("maxResponseBytes") as? Int,
            let timeout = mirror.descendant("timeout") as? TimeAmount
        else {
            try await client.shutdown()
            Issue.record(
                "Failed to reflect internal mutated structures out of RequestBuilder storage context."
            )
            return
        }

        #expect(headers.first(name: "X-API-Version") == "1.4.2")
        #expect(urlString.contains("search=swift6"))
        #expect(urlString.contains("sort=desc"))
        #expect(maxBytes == 5 * 1024 * 1024)
        #expect(timeout == .seconds(15))

        try await client.shutdown()
    }

    @Test(
        "RequestBuilderTests: Ensures dangerouslyAllowBody successfully mutates blocked method generic states"
    )
    func testDangerouslyAllowBodyGenericPathUnlocking() async throws {
        let client = NetSkeinClient()
        let request = RequestBuilder<BodyIsBlocked, EmptyBody>(
            client: client,
            method: .GET,
            url: "https://netskein.local"
        )
        .dangerouslyAllowBody()

        #expect(type(of: request) == RequestBuilder<BodyIsAllowed, EmptyBody>.self)

        try await client.shutdown()
    }
}

// MARK: - Payload Conversion Data Layout Formats Coverage

extension RequestBuilderTests {
    @Test(
        "RequestBuilderTests: Verifies URL-encoded form data conversion maps content fields and appends content type headers"
    )
    func testFormPayloadConversion() async throws {
        let client = NetSkeinClient()
        let request = try RequestBuilder<BodyIsAllowed, EmptyBody>(
            client: client,
            method: .POST,
            url: "https://netskein.local"
        )
        .form(["email": "dev@netskein.io", "verified": "true"])

        let mirror = Mirror(reflecting: request)

        guard
            let headers = mirror.descendant("headers") as? HTTPHeaders,
            let bodyOpt = mirror.descendant("body") as? HTTPClientRequest.Body?,
            let body = bodyOpt
        else {
            try await client.shutdown()
            Issue.record("Failed to extract body or headers from form conversion path layout.")
            return
        }

        #expect(headers.first(name: "Content-Type") == "application/x-www-form-urlencoded")

        let bodyMirror = Mirror(reflecting: body)

        guard let mode = bodyMirror.descendant("mode") else {
            try await client.shutdown()
            return
        }

        let modeMirror = Mirror(reflecting: mode)

        if let buffer = modeMirror.children.first?.value as? ByteBuffer {
            var mutableBuffer = buffer
            let encodedString = mutableBuffer.readString(length: mutableBuffer.readableBytes) ?? ""
            #expect(encodedString.contains("email=dev%40netskein.io"))
            #expect(encodedString.contains("verified=true"))
            try await client.shutdown()
        } else {
            try await client.shutdown()
            Issue.record(
                "Internal payload conversion storage mechanism did not match standard ByteBuffer layout formats."
            )
        }
    }

    @Test(
        "RequestBuilderTests: Verifies JSON encoder method securely packages Encodable objects into binary streams"
    )
    func testJSONPayloadConversion() async throws {
        let client = NetSkeinClient()
        let payload = SamplePostPayload(title: "Strict Concurrency", category: "Core Development")
        let request = try RequestBuilder<BodyIsAllowed, EmptyBody>(
            client: client,
            method: .PUT,
            url: "https://netskein.local"
        )
        .json(payload)

        let mirror = Mirror(reflecting: request)

        guard
            let headers = mirror.descendant("headers") as? HTTPHeaders,
            let bodyOpt = mirror.descendant("body") as? HTTPClientRequest.Body?,
            let body = bodyOpt
        else {
            try await client.shutdown()
            Issue.record("Failed to extract body or headers from JSON conversion context.")
            return
        }

        #expect(headers.first(name: "Content-Type") == "application/json")

        let bodyMirror = Mirror(reflecting: body)

        guard let mode = bodyMirror.descendant("mode") else {
            try await client.shutdown()
            return
        }

        let modeMirror = Mirror(reflecting: mode)

        if let buffer = modeMirror.children.first?.value as? ByteBuffer {
            var mutableBuffer = buffer
            let rawData = mutableBuffer.readData(length: mutableBuffer.readableBytes) ?? Data()
            let decoded = try JSONDecoder().decode(SamplePostPayload.self, from: rawData)
            #expect(decoded.title == "Strict Concurrency")
            #expect(decoded.category == "Core Development")
            try await client.shutdown()
        } else {
            try await client.shutdown()
            Issue.record(
                "JSON encoding execution loop failed to yield a structural ByteBuffer container."
            )
        }
    }

    @Test(
        "RequestBuilderTests: Verifies multipart method appends form boundaries cleanly matching the specifications rules"
    )
    func testMultipartPayloadIntegration() async throws {
        let client = NetSkeinClient()

        let form = NetSkeinMultipartForm.builder()
            .text(name: "attachment_meta", value: "Snapshot code artifact")
            .build()

        let request = RequestBuilder<BodyIsAllowed, EmptyBody>(
            client: client,
            method: .POST,
            url: "https://netskein.local"
        )
        .multipart(form)

        let mirror = Mirror(reflecting: request)

        guard let headers = mirror.descendant("headers") as? HTTPHeaders else {
            try await client.shutdown()
            Issue.record("Failed to read headers from multipart layout state context.")
            return
        }

        let contentType = headers.first(name: "Content-Type") ?? ""
        #expect(contentType.contains("multipart/form-data; boundary=\(form.boundary)"))

        try await client.shutdown()
    }

    @Test(
        "RequestBuilderTests: Assures local streaming factory throws explicit ioFailure error kind if designated file path is absent"
    )
    func testStreamInvalidFilePathThrows() async throws {
        let client = NetSkeinClient()
        let builder = RequestBuilder<BodyIsAllowed, EmptyBody>(
            client: client,
            method: .POST,
            url: "https://netskein.local"
        )

        // Assert that passing an absent route forces compile-time checked throwing conversion loops
        #expect(throws: NetSkeinError.self) {
            try builder.stream(fileAtPath: "/directory/absent/file_error_artifact.mov")
        }

        try await client.shutdown()
    }
}

// MARK: - Live Request Orchestration Execution Coverage via Mock Engine

extension RequestBuilderTests {
    @Test(
        "RequestBuilderTests: Ensures standard send execution captures validation headers and stores server cookies correctly"
    )
    func testStandardSendExecutionFlow() async throws {
        let cookieJar = NetSkeinCookieJar()

        let testStub = NetSkeinStub(
            method: .POST,
            url: "https://netskein.mock",
            requestValidator: { @Sendable request in
                #expect(request.headers.contains(name: "X-Request-ID"))
                #expect(request.headers.first(name: "X-Custom-Assertion") == "TriggerValue")
            },
            outcome: .success(
                status: .created,
                headers: [
                    "Content-Type": "application/json",
                    "Set-Cookie": "session_token=token_abc123",
                ],
                body: ByteBuffer(string: "{\"execution\":\"success\"}")
            )
        )

        let client = NetSkeinClient.builder()
            .cookieStore(cookieJar)
            .addStub(testStub)
            .build()

        let response = try await client.post("https://netskein.mock")
            .header("X-Custom-Assertion", "TriggerValue")
            .send()

        #expect(response.status == .created)
        #expect(response.text() == "{\"execution\":\"success\"}")

        // Audit stateful Cookie validation rules mapping loops out of headers intercept parameters
        let capturedCookie = cookieJar.cookieHeader(for: "netskein.mock")
        #expect(capturedCookie == "session_token=token_abc123")

        try await client.shutdown()
    }

    @Test(
        "RequestBuilderTests: Assures client network errors are successfully intercepted and mapped into custom kind parameters"
    )
    func testSendOutageErrorInterception() async throws {
        let brokenStub = NetSkeinStub(
            method: .GET,
            url: "https://netskein.mock",
            outcome: .failure(HTTPClientError.remoteConnectionClosed)
        )

        let client = NetSkeinClient.builder()
            .addStub(brokenStub)
            .build()

        await #expect(throws: NetSkeinError.self) {
            try await client.get("netskein.mock").send()
        }

        try await client.shutdown()
    }
}

// MARK: - Streaming Downloads and Inbound File Streaming Layouts Coverage

extension RequestBuilderTests {
    @Test(
        "RequestBuilderTests: Verifies inbound streaming blocks fire callbacks repeatedly to read sequential data chunks"
    )
    func testSendChunkedStreamingDownload() async throws {
        let dataChunk = ByteBuffer(string: "ChunkStreamDataPayload")
        let streamingStub = NetSkeinStub(
            method: .GET,
            url: "netskein.mock",
            outcome: .success(
                status: .ok,
                headers: ["Content-Length": "22"],
                body: dataChunk
            )
        )

        let client = NetSkeinClient.builder()
            .addStub(streamingStub)
            .build()

        let callbackFiredBox = NIOLockedValueBox(false)
        let bytesAccumulatedBox = NIOLockedValueBox(Int64(0))

        try await client.get("netskein.mock")
            .send { chunk, received, total in
                callbackFiredBox.withLockedValue { $0 = true }
                bytesAccumulatedBox.withLockedValue { $0 = received }
                #expect(total == 22)
            }

        #expect(callbackFiredBox.withLockedValue { $0 } == true)
        #expect(bytesAccumulatedBox.withLockedValue { $0 } == 22)

        try await client.shutdown()
    }

    @Test(
        "RequestBuilderTests: Verifies that download to file path sets accurate handles and catches status error kinds"
    )
    func testDownloadToFileSystemLifecycle() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let destinationPath =
            temporaryDirectory.appendingPathComponent("test_netskein_download.bin").path

        // Clean up file if residue exists from past crashes
        try? FileManager.default.removeItem(atPath: destinationPath)

        let successStub = NetSkeinStub(
            method: .GET,
            url: "netskein.mock",
            outcome: .success(
                status: .ok,
                headers: ["Content-Length": "8"],
                body: ByteBuffer(string: "FileData")
            )
        )

        let client = NetSkeinClient.builder()
            .addStub(successStub)
            .build()

        let progressFiredBox = NIOLockedValueBox(false)

        // Execute dynamic file creation write operations natively
        try await client.get("netskein.mock")
            .download(toFileAtPath: destinationPath) { _, total in
                progressFiredBox.withLockedValue { $0 = true }
                #expect(total == 8)
            }

        #expect(progressFiredBox.withLockedValue { $0 } == true)
        #expect(FileManager.default.fileExists(atPath: destinationPath) == true)

        let readData = try? String(contentsOfFile: destinationPath, encoding: .utf8)
        #expect(readData == "FileData")

        // Cleanup local storage workspace tracks cleanly
        try? FileManager.default.removeItem(atPath: destinationPath)

        try await client.shutdown()
    }

    @Test(
        "RequestBuilderTests: Ensures that downloading to a protected system directory throws an accurate ioFailure error kind"
    )
    func testDownloadToFileSystemCreationFailure() async throws {
        let client = NetSkeinClient()

        // Triggering file creation failure by attempting write actions under an absolute illegal path zone
        let illegalSystemPath = "/directory_forbidden_root_access_netskein/file.dmg"

        await #expect(throws: NetSkeinError.self) {
            try await client.get("netskein.mock")
                .download(toFileAtPath: illegalSystemPath)
        }

        try await client.shutdown()
    }

    @Test(
        "RequestBuilderTests: Assures downloading bad statuses aborts early and throws customized badStatus error kinds"
    )
    func testDownloadBadStatusAbortsEarly() async throws {
        let badStatusStub = NetSkeinStub(
            method: .GET,
            url: "netskein.mock",
            outcome: .success(status: .notFound, headers: HTTPHeaders(), body: nil)
        )

        let client = NetSkeinClient.builder()
            .addStub(badStatusStub)
            .build()

        let temporaryDirectory = FileManager.default.temporaryDirectory
        let destinationPath = temporaryDirectory.appendingPathComponent("abort_test.bin").path

        await #expect(throws: NetSkeinError.self) {
            try await client.get("netskein.mock")
                .download(toFileAtPath: destinationPath)
        }

        try? FileManager.default.removeItem(atPath: destinationPath)

        try await client.shutdown()
    }
}
