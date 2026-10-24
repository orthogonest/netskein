import Foundation
import NIOCore
import Testing

@testable import NetSkein

struct MultipartFormTests {
    @Test(
        "MultipartFormTests: Verifies explicit initialization holds correct inputs independent of builder"
    )
    func testPublicInitializerLayout() {
        let allocator = ByteBufferAllocator()
        var mockBuffer = allocator.buffer(capacity: 4)
        mockBuffer.writeString("data")

        let customBoundary = "CustomMockBoundary123"
        let parts = [
            MultipartForm.Part(
                name: "field",
                filename: nil,
                contentType: "text/plain",
                body: mockBuffer
            )
        ]

        let form = MultipartForm(boundary: customBoundary, parts: parts)

        #expect(form.boundary == customBoundary)
        #expect(form.parts.count == 1)
        #expect(form.parts[0].name == "field")
        #expect(form.parts[0].contentType == "text/plain")
    }

    @Test(
        "MultipartFormTests: Ensures estimatedLength perfectly matches manual byte size allocations"
    )
    func testEstimatedLengthPrecision() {
        let allocator = ByteBufferAllocator()
        var mockImageBuffer = allocator.buffer(capacity: 5)
        mockImageBuffer.writeBytes([0x01, 0x02, 0x03, 0x04, 0x05])

        let form = MultipartForm.builder()
            .text(name: "caption", value: "Hello")
            .file(
                name: "photo",
                filename: "test.jpg",
                contentType: "image/jpeg",
                body: mockImageBuffer
            )
            .build()

        let boundaryCount = form.boundary.utf8.count
        var expectedTotal = 0

        // Part 1: Text ("caption" -> "Hello")
        var part1Len = 4 + boundaryCount  // "--" + boundary + "\r\n"
        // "Content-Disposition: form-data; name=\"caption\"\r\n"
        part1Len += 41 + "caption".utf8.count
        part1Len += 2  // "\r\n" separator
        part1Len += 5  // "Hello".utf8.count
        part1Len += 2  // "\r\n"
        expectedTotal += part1Len

        // Part 2: File ("photo", "test.jpg", "image/jpeg" -> 5 bytes)
        var part2Len = 4 + boundaryCount  // "--" + boundary + "\r\n"
        // "Content-Disposition: form-data; name=\"photo\"; filename=\"test.jpg\"\r\n"
        part2Len += 54 + "photo".utf8.count + "test.jpg".utf8.count
        part2Len += 16 + "image/jpeg".utf8.count  // "Content-Type: image/jpeg\r\n"
        part2Len += 2  // "\r\n" separator
        part2Len += 5  // 5 bytes data
        part2Len += 2  // "\r\n"
        expectedTotal += part2Len

        // End Boundary
        expectedTotal += 6 + boundaryCount  // "--" + boundary + "--\r\n"

        #expect(form.estimatedLength == expectedTotal)
    }

    @Test(
        "MultipartFormTests: Verifies that serialized bytes perfectly match the formal multipart payload layout"
    )
    func testBytesSerializationPayloadLayout() {
        let allocator = ByteBufferAllocator()
        var mockFileBytes = allocator.buffer(capacity: 3)
        mockFileBytes.writeBytes([0x41, 0x42, 0x43])  // "ABC"

        let form = MultipartForm.builder()
            .text(name: "status", value: "active")
            .file(
                name: "document",
                filename: "doc.txt",
                contentType: "text/plain",
                body: mockFileBytes
            )
            .build()

        // Execute serialization
        var serializedBuffer = form.bytes()
        let totalBytesGenerated = serializedBuffer.readableBytes

        // Extract full payload as String for human-readable layout assertion
        guard let payloadString = serializedBuffer.readString(length: totalBytesGenerated) else {
            Issue.record(
                "Failed to read string configuration out of serialized ByteBuffer container."
            )
            return
        }

        // Reconstruct expected raw layout based on boundary configuration
        let expectedPayload =
            "--\(form.boundary)\r\n" + "Content-Disposition: form-data; name=\"status\"\r\n"
            + "\r\n" + "active\r\n" + "--\(form.boundary)\r\n"
            + "Content-Disposition: form-data; name=\"document\"; filename=\"doc.txt\"\r\n"
            + "Content-Type: text/plain\r\n" + "\r\n" + "ABC\r\n" + "--\(form.boundary)--\r\n"

        #expect(payloadString == expectedPayload)
    }

    @Test(
        "MultipartFormTests: Ensures estimatedLength matches the actual readable bytes count of the serialized payload"
    )
    func testEstimatedLengthMatchesActualSerializedBytesCount() {
        let allocator = ByteBufferAllocator()
        var randomDataBuffer = allocator.buffer(capacity: 8)
        randomDataBuffer.writeBytes([0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80])

        let form = MultipartForm.builder()
            .text(name: "notes", value: "Swift 6 Concurrency Safe Loops")
            .file(
                name: "payload",
                filename: "blob.bin",
                contentType: "application/octet-stream",
                body: randomDataBuffer
            )
            .build()

        let preCalculatedLength = form.estimatedLength
        let actualSerializedLength = form.bytes().readableBytes

        #expect(preCalculatedLength == actualSerializedLength)
    }
}

struct MultipartFormBuilderTests {
    @Test(
        "MultipartFormBuilderTests: Ensures non-mutating chaining cleanly mutates isolated return instances without side-effects"
    )
    func testNonMutatingBuilderIsolation() {
        let baseBuilder = MultipartForm.builder()

        // Chaining creates independent stack allocations
        let firstDerivation = baseBuilder.text(name: "key1", value: "val1")
        let secondDerivation = firstDerivation.text(name: "key2", value: "val2")

        let form1 = firstDerivation.build()
        let form2 = secondDerivation.build()

        // Assert state propagation is fully isolated
        #expect(form1.parts.count == 1)
        #expect(form1.parts[0].name == "key1")

        #expect(form2.parts.count == 2)
        #expect(form2.parts[0].name == "key1")
        #expect(form2.parts[1].name == "key2")
    }

    @Test(
        "MultipartFormBuilderTests: Verifies text parts are accurately appended and text content matches"
    )
    func testTextPartBuilder() {
        let form = MultipartForm.builder()
            .text(name: "username", value: "swift_developer")
            .build()

        #expect(form.parts.count == 1)

        let textPart = form.parts[0]
        #expect(textPart.name == "username")
        #expect(textPart.filename == nil)
        #expect(textPart.contentType == nil)

        // Ensure string conversion matches original value
        var bodyBuffer = textPart.body
        let stringContent = bodyBuffer.readString(length: bodyBuffer.readableBytes)
        #expect(stringContent == "swift_developer")
    }

    @Test(
        "MultipartFormBuilderTests: Verifies file parts are accurately appended with correct headers and bytes"
    )
    func testFilePartBuilder() {
        let allocator = ByteBufferAllocator()
        var mockFileBytes = allocator.buffer(capacity: 4)
        mockFileBytes.writeBytes([0x89, 0x50, 0x4E, 0x47])  // PNG Magic bytes

        let form = MultipartForm.builder()
            .file(
                name: "avatar",
                filename: "profile.png",
                contentType: "image/png",
                body: mockFileBytes
            )
            .build()

        #expect(form.parts.count == 1)

        let filePart = form.parts[0]
        #expect(filePart.name == "avatar")
        #expect(filePart.filename == "profile.png")
        #expect(filePart.contentType == "image/png")
        #expect(filePart.body.readableBytes == 4)
    }

    @Test(
        "MultipartFormBuilderTests: Allocates unique UUID-based boundary tokens across separate instances"
    )
    func testUniqueBoundaryGeneration() {
        let form1 = MultipartForm.builder().build()
        let form2 = MultipartForm.builder().build()

        #expect(form1.boundary != form2.boundary)
        #expect(form1.boundary.contains("NetSkeinBoundary-"))
    }
}
