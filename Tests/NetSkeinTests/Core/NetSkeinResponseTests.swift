import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import Testing

@testable import NetSkein

struct NetSkeinResponseTests {
    struct SampleUser: Codable, Equatable {
        let id: Int
        let name: String
    }

    @Test("NetSkeinResponseTests: Verifies successful body collection and basic extraction methods")
    func testSuccessfulResponseCollection() async throws {
        let allocator = ByteBufferAllocator()
        var mockBody = allocator.buffer(capacity: 12)
        mockBody.writeString("Hello NetSkein")

        let clientResponse = HTTPClientResponse(
            status: .ok,
            headers: ["Content-Type": "text/plain"],
            body: .bytes(mockBody)
        )

        let response = try await NetSkeinResponse(
            underlyingResponse: clientResponse,
            maxBytes: 1024
        )

        #expect(response.status == .ok)
        #expect(response.headers.first(name: "Content-Type") == "text/plain")
        #expect(response.bytes()?.readableBytes == 14)
        #expect(response.text() == "Hello NetSkein")
    }

    @Test(
        "NetSkeinResponseTests: Ensures empty response bodies return nil when parsing to text"
    )
    func testTextEmptyBodyNil() async throws {
        let clientResponse = HTTPClientResponse(status: .ok, body: .bytes(ByteBuffer()))
        let response = try await NetSkeinResponse(underlyingResponse: clientResponse, maxBytes: 10)

        #expect(response.text() == nil)
    }

    @Test(
        "NetSkeinResponseTests: Verifies errorForStatus returns self on 2xx and throws badStatus on non-2xx codes"
    )
    func testErrorForStatusBehavior() async throws {
        // Test Success Case (HTTP 200)
        let successClientResponse = HTTPClientResponse(status: .ok, body: .bytes(ByteBuffer()))
        let successResponse = try await NetSkeinResponse(
            underlyingResponse: successClientResponse,
            maxBytes: 10
        )

        // Should not throw and return self
        let verifiedResponse = try successResponse.errorForStatus()
        #expect(verifiedResponse.status == .ok)

        // Test Failure Case (HTTP 404)
        let failureClientResponse = HTTPClientResponse(
            status: .notFound,
            body: .bytes(ByteBuffer())
        )
        let failureResponse = try await NetSkeinResponse(
            underlyingResponse: failureClientResponse,
            maxBytes: 10
        )

        // Should throw NetSkeinError with clientError kind
        #expect(throws: NetSkeinError.self) {
            try failureResponse.errorForStatus()
        }
    }

    @Test("NetSkeinResponseTests: Verifies clean JSON decoding into concrete Decodable models")
    func testJSONDecodingSuccess() async throws {
        let allocator = ByteBufferAllocator()
        var jsonBuffer = allocator.buffer(capacity: 32)
        jsonBuffer.writeString("{\"id\": 42, \"name\": \"John Doe\"}")

        let clientResponse = HTTPClientResponse(status: .ok, body: .bytes(jsonBuffer))
        let response = try await NetSkeinResponse(underlyingResponse: clientResponse, maxBytes: 100)

        let user = try response.json(SampleUser.self)
        #expect(user == SampleUser(id: 42, name: "John Doe"))
    }

    @Test(
        "NetSkeinResponseTests: Ensures empty response bodies throw emptyResponseBody when parsing JSON"
    )
    func testJSONDecodingEmptyBodyThrows() async throws {
        let clientResponse = HTTPClientResponse(status: .ok, body: .bytes(ByteBuffer()))
        let response = try await NetSkeinResponse(underlyingResponse: clientResponse, maxBytes: 10)

        #expect(throws: NetSkeinError.self) {
            try response.json(SampleUser.self)
        }
    }

    @Test(
        "NetSkeinResponseTests: Ensures malformed JSON layouts throw custom invalidPayload error kind"
    )
    func testJSONDecodingMalformedThrows() async throws {
        let allocator = ByteBufferAllocator()
        var brokenJson = allocator.buffer(capacity: 10)
        brokenJson.writeString("{ invalid-json }")

        let clientResponse = HTTPClientResponse(status: .ok, body: .bytes(brokenJson))
        let response = try await NetSkeinResponse(underlyingResponse: clientResponse, maxBytes: 100)

        #expect(throws: NetSkeinError.self) {
            try response.json(SampleUser.self)
        }
    }

    @Test(
        "NetSkeinResponseTests: Ensures body collection throws networkFailure when exceeding maxBytes payload threshold"
    )
    func testMaxBytesThresholdBreachThrows() async throws {
        let allocator = ByteBufferAllocator()
        var oversizedBuffer = allocator.buffer(capacity: 20)
        oversizedBuffer.writeString("This is a very long text")  // 24 bytes

        let clientResponse = HTTPClientResponse(status: .ok, body: .bytes(oversizedBuffer))

        // Should throw NetSkeinError during initialization due to collect(upTo:) threshold breach
        await #expect(throws: NetSkeinError.self) {
            // Max received 5 bytes
            try await NetSkeinResponse(underlyingResponse: clientResponse, maxBytes: 5)
        }
    }
}
