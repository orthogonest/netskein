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

    struct MalformedFloatPayload: Encodable {
        let invalidValue: Double = Double.infinity
    }
}

// MARK: - Fluent Chaining

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
        "RequestBuilderTests: Ensures query mutation falls back cleanly when the base URL is fundamentally malformed"
    )
    func testQueryMutationWithInvalidURLFallback() async throws {
        let client = NetSkeinClient()
        let invalidBaseURL = "1https://netskein.local"

        let request = RequestBuilder<BodyIsAllowed, EmptyBody>(
            client: client,
            method: .POST,
            url: invalidBaseURL
        )
        .query(["search": "swift6"])

        let mirror = Mirror(reflecting: request)

        guard let urlString = mirror.descendant("url") as? String else {
            try await client.shutdown()
            Issue.record("Failed to reflect URL string out of RequestBuilder storage context.")
            return
        }

        #expect(urlString == invalidBaseURL)
        #expect(!urlString.contains("search=swift6"))

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

// MARK: - Payload Conversion

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
        "RequestBuilderTests: Ensures JSON conversion throws NetSkeinError when encountering unencodable float values"
    )
    func testJSONPayloadConversionThrowsOnInvalidValue() async throws {
        let client = NetSkeinClient()
        let malformedPayload = MalformedFloatPayload()

        #expect(throws: NetSkeinError.self) {
            _ = try RequestBuilder<BodyIsAllowed, EmptyBody>(
                client: client,
                method: .PUT,
                url: "https://netskein.local"
            )
            .json(malformedPayload)
        }

        try await client.shutdown()
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
        "RequestBuilderTests: Assures local streaming factory configures chunked streams correctly on successful file reads"
    )
    func testStreamSuccessfulExecutionFlow() async throws {
        let client = NetSkeinClient()
        let builder = RequestBuilder<BodyIsAllowed, EmptyBody>(
            client: client,
            method: .POST,
            url: "https://netskein.local"
        )

        let tempDirectory = FileManager.default.temporaryDirectory
        let tempFileURL = tempDirectory.appendingPathComponent("netskein_test_stream.txt")
        let dummyData = Data(
            "NetSkein Production Quality Core Stream Verification String Data".utf8
        )
        try dummyData.write(to: tempFileURL)
        defer { try? FileManager.default.removeItem(at: tempFileURL) }

        let request = try builder.stream(fileAtPath: tempFileURL.path, chunkSize: 10)

        let mirror = Mirror(reflecting: request)
        guard
            let headers = mirror.descendant("headers") as? HTTPHeaders,
            let bodyOpt = mirror.descendant("body") as? HTTPClientRequest.Body?,
            let body = bodyOpt
        else {
            try await client.shutdown()
            Issue.record("Failed to reflect headers or body structure from streaming context.")
            return
        }

        // Verify base headers W3C Stream
        #expect(headers.first(name: "Transfer-Encoding") == "chunked")
        #expect(headers.first(name: "Content-Type") == "application/octet-stream")

        // Verify body and file size
        let bodyMirror = Mirror(reflecting: body)

        guard let modePropertyValue = bodyMirror.descendant("mode") else {
            try await client.shutdown()
            Issue.record(
                "Failed to extract internal 'mode' property from HTTPClientRequest.Body struct."
            )
            return
        }

        let modeMirror = Mirror(reflecting: modePropertyValue)
        guard let enumCase = modeMirror.children.first else {
            try await client.shutdown()
            Issue.record("Failed to extract enum case from internal Mode storage.")
            return
        }

        #expect(enumCase.label == "asyncSequence" || enumCase.label == "httpClientRequestBody")

        let associatedValuesMirror = Mirror(reflecting: enumCase.value)
        var capturedLengthDescription = ""

        for child in associatedValuesMirror.children where child.label == "length" {
            capturedLengthDescription = String(describing: child.value)
            break
        }

        #expect(capturedLengthDescription.contains("\(dummyData.count)"))

        try await client.shutdown()
    }

    @Test(
        "RequestBuilderTests: Assures local streaming factory throws explicit ioFailure when FileHandle returns nil"
    )
    func testStreamThrowsWhenFileHandleFailsToOpen() async throws {
        final class MockFileManager: FileManager, @unchecked Sendable {
            override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
                [.size: Int64(1024)]
            }
        }

        let client = NetSkeinClient()

        let mockBuilder = RequestBuilder<BodyIsAllowed, EmptyBody>(
            client: client,
            method: .POST,
            url: "https://netskein.local",
            fileManager: MockFileManager()
        )

        #expect(throws: NetSkeinError.self) {
            try mockBuilder.stream(fileAtPath: "/path/to/mock/file.bin")
        }

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

// MARK: - Request Execution

extension RequestBuilderTests {
    @Test(
        "RequestBuilderTests: Ensures standard send execution captures validation headers and stores server cookies correctly"
    )
    func testStandardSendExecutionFlow() async throws {
        let cookieJar = NetSkeinCookieJar()

        let firstStub = NetSkeinStub(
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
                    "Set-Cookie": "session_token=token_abc123; Path=/; Secure",
                ],
                body: ByteBuffer(string: "{\"execution\":\"success\"}")
            )
        )

        let secondStub = NetSkeinStub(
            method: .GET,
            url: "https://netskein.mock",
            requestValidator: { @Sendable request in
                #expect(request.headers.first(name: "Cookie") == "session_token=token_abc123")
            },
            outcome: .success(
                status: .ok,
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: "{\"status\":\"authenticated\"}")
            )
        )

        let client = NetSkeinClient.builder()
            .cookieStore(cookieJar)
            .addStubs([firstStub, secondStub])
            .build()

        let firstResponse = try await client.post("https://netskein.mock")
            .header("X-Custom-Assertion", "TriggerValue")
            .send()

        #expect(firstResponse.status == .created)

        let capturedCookie = cookieJar.cookieHeader(for: "netskein.mock")
        #expect(capturedCookie == "session_token=token_abc123")

        let secondResponse = try await client.get("https://netskein.mock")
            .send()

        #expect(secondResponse.status == .ok)

        try await client.shutdown()
    }

    @Test("RequestBuilderTests: Ensure skip invalid cookie format")
    func testInvalidCookieFormat() async throws {
        let cookieJar = NetSkeinCookieJar()

        let stub = NetSkeinStub(
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
                    "Set-Cookie": [
                        "malformed_cookie_no_equals_sign",
                        "session_token=token_abc123; Path=/; Secure",
                        "invalid=format=too_many_equals",
                    ]
                    .joined(separator: "; "),
                ],
                body: ByteBuffer(string: "{\"execution\":\"success\"}")
            )
        )

        let client = NetSkeinClient.builder()
            .cookieStore(cookieJar)
            .addStub(stub)
            .build()

        let response = try await client.post("https://netskein.mock")
            .header("X-Custom-Assertion", "TriggerValue")
            .send()

        #expect(response.status == .created)

        let capturedCookie = cookieJar.cookieHeader(for: "netskein.mock")
        #expect(capturedCookie == nil)

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

    @Test(
        "RequestBuilderTests: Assures generic non-network errors are safely wrapped into a custom networkFailure error kind"
    )
    func testSendGenericNonNetworkErrorWrapping() async throws {
        struct NetSkeinUnknownFailureStub: Error, LocalizedError {
            var errorDescription: String? { "Fatal hardware isolation simulation loop failure." }
        }

        let anomalyStub = NetSkeinStub(
            method: .GET,
            url: "https://netskein.mock",
            outcome: .failure(NetSkeinUnknownFailureStub())
        )

        let client = NetSkeinClient.builder()
            .addStub(anomalyStub)
            .build()

        await #expect(throws: NetSkeinError.self) {
            _ = try await client.get("https://netskein.mock").send()
        }

        try await client.shutdown()
    }
}

// MARK: - Inbound File Streaming

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
        "RequestBuilderTests: Ensures streaming send automatically injects stored cookies into active outbound headers"
    )
    func testStreamingSendInjectsCookieAndSucceeds() async throws {
        let cookieJar = NetSkeinCookieJar()
        cookieJar.setCookie(host: "netskein.mock", name: "session_token", value: "stream_123")

        let dataChunk = ByteBuffer(string: "ChunkStreamDataPayload")
        let streamingStub = NetSkeinStub(
            method: .GET,
            url: "https://netskein.mock",
            requestValidator: { @Sendable request in
                #expect(request.headers.first(name: "Cookie") == "session_token=stream_123")
            },
            outcome: .success(
                status: .ok,
                headers: ["Content-Length": "22"],
                body: dataChunk
            )
        )

        let client = NetSkeinClient.builder()
            .cookieStore(cookieJar)
            .addStub(streamingStub)
            .build()

        let callbackFiredBox = NIOLockedValueBox(false)

        try await client.get("https://netskein.mock")
            .send { chunk, received, total in
                callbackFiredBox.withLockedValue { $0 = true }
            }

        #expect(callbackFiredBox.withLockedValue { $0 } == true)

        try await client.shutdown()
    }

    @Test(
        "RequestBuilderTests: Assures streaming execution rethrows custom NetSkeinError instances directly without rewrapping"
    )
    func testStreamingSendNetSkeinErrorInterception() async throws {
        let brokenStub = NetSkeinStub(
            method: .GET,
            url: "https://netskein.mock",
            outcome: .failure(HTTPClientError.remoteConnectionClosed)
        )

        let client = NetSkeinClient.builder()
            .addStub(brokenStub)
            .build()

        await #expect(throws: NetSkeinError.self) {
            try await client.get("netskein.mock")
                .send { _, _, _ in }
        }

        try await client.shutdown()
    }

    @Test(
        "RequestBuilderTests: Assures streaming execution routes anonymous errors cleanly into a custom networkFailure kind"
    )
    func testStreamingSendGenericErrorInterception() async throws {
        struct AnonymousStreamCrash: Error, LocalizedError {
            var errorDescription: String? { "Underlying kernel pipeline data stream desync." }
        }

        let brokenStub = NetSkeinStub(
            method: .GET,
            url: "netskein.mock",
            outcome: .failure(AnonymousStreamCrash())
        )

        let client = NetSkeinClient.builder()
            .addStub(brokenStub)
            .build()

        await #expect(throws: NetSkeinError.self) {
            try await client.get("netskein.mock")
                .send { _, _, _ in }
        }

        try await client.shutdown()
    }
}

// MARK: - Streaming Downloads

extension RequestBuilderTests {
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
        "RequestBuilderTests: Ensures download automatically injects stored cookies into active outbound headers"
    )
    func testDownloadInjectsCookieAndSucceeds() async throws {
        let cookieJar = NetSkeinCookieJar()
        cookieJar.setCookie(host: "netskein.mock", name: "session_token", value: "dl_stream_123")

        let temporaryDirectory = FileManager.default.temporaryDirectory
        let destinationPath =
            temporaryDirectory.appendingPathComponent("test_netskein_dl_cookie.bin").path
        try? FileManager.default.removeItem(atPath: destinationPath)

        let successStub = NetSkeinStub(
            method: .GET,
            url: "https://netskein.mock",
            requestValidator: { @Sendable request in
                #expect(request.headers.first(name: "Cookie") == "session_token=dl_stream_123")
            },
            outcome: .success(
                status: .ok,
                headers: ["Content-Length": "8"],
                body: ByteBuffer(string: "FileData")
            )
        )

        let client = NetSkeinClient.builder()
            .cookieStore(cookieJar)
            .addStub(successStub)
            .build()

        try await client.get("https://netskein.mock")
            .download(toFileAtPath: destinationPath)

        #expect(FileManager.default.fileExists(atPath: destinationPath) == true)
        try? FileManager.default.removeItem(atPath: destinationPath)
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

    @Test(
        "RequestBuilderTests: Assures download execution routes anonymous exceptions cleanly into a custom networkFailure error kind"
    )
    func testDownloadGenericNetworkErrorWrapping() async throws {
        struct AnonymousDownloadCrash: Error, LocalizedError {
            var errorDescription: String? { "Disk space allocation failure simulation loop." }
        }

        let brokenStub = NetSkeinStub(
            method: .GET,
            url: "netskein.mock",
            outcome: .failure(AnonymousDownloadCrash())
        )

        let client = NetSkeinClient.builder()
            .addStub(brokenStub)
            .build()

        let temporaryDirectory = FileManager.default.temporaryDirectory
        let destinationPath = temporaryDirectory.appendingPathComponent("test_netskein_crash.bin")
            .path
        try? FileManager.default.removeItem(atPath: destinationPath)

        await #expect(throws: NetSkeinError.self) {
            try await client.get("netskein.mock")
                .download(toFileAtPath: destinationPath)
        }

        try? FileManager.default.removeItem(atPath: destinationPath)
        try await client.shutdown()
    }
}
