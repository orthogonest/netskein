import NIOConcurrencyHelpers
import NIOCore

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public struct NetSkeinMultipartForm: Sendable {
    public struct Part: Sendable {
        public let name: String
        public let filename: String?
        public let contentType: String?
        public let body: ByteBuffer
    }

    let boundary: String
    let parts: [Part]

    public init(
        boundary: String,
        parts: [Part]
    ) {
        self.boundary = boundary
        self.parts = parts
    }

    public static func builder() -> NetSkeinMultipartFormBuilder { NetSkeinMultipartFormBuilder() }
}

extension NetSkeinMultipartForm {
    public var estimatedLength: Int {
        var total = 0
        for part in parts {
            total += 4 + boundary.utf8.count  // "--" + boundary + "\r\n"

            if let filename = part.filename {
                // "Content-Disposition: form-data; name=\"\"; filename=\"\"\r\n"
                // Fixed structural characters count is exactly 47
                total += 54 + part.name.utf8.count + filename.utf8.count
            } else {
                // "Content-Disposition: form-data; name=\"\"\r\n"
                // Fixed structural characters count is exactly 33
                total += 41 + part.name.utf8.count
            }

            if let contentType = part.contentType {
                total += 16 + contentType.utf8.count  // "Content-Type: ...\r\n"
            }

            total += 2  // "\r\n" header and body part separator
            total += part.body.readableBytes  // Payload part size
            total += 2  // "\r\n"
        }
        total += 6 + boundary.utf8.count  // "--" + boundary + "--\r\n"
        return total
    }

    public func bytes() -> ByteBuffer {
        let allocator = ByteBufferAllocator()
        var buffer = allocator.buffer(capacity: estimatedLength)

        for part in parts {
            buffer.writeString("--\(boundary)\r\n")

            if let filename = part.filename {
                buffer.writeString(
                    "Content-Disposition: form-data; name=\"\(part.name)\"; filename=\"\(filename)\"\r\n"
                )
            } else {
                buffer.writeString(
                    "Content-Disposition: form-data; name=\"\(part.name)\"\r\n"
                )
            }

            if let contentType = part.contentType {
                buffer.writeString("Content-Type: \(contentType)\r\n")
            }

            buffer.writeString("\r\n")

            if let slice = part.body.getSlice(
                at: part.body.readerIndex,
                length: part.body.readableBytes
            ) {
                var tempSlice = slice
                buffer.writeBuffer(&tempSlice)
            }

            buffer.writeString("\r\n")
        }

        buffer.writeString("--\(boundary)--\r\n")

        return buffer
    }
}

public struct NetSkeinMultipartFormBuilder: Sendable {
    private let boundary: String
    private var parts: [NetSkeinMultipartForm.Part]

    public init() {
        let uniqueID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        boundary = "NetSkeinBoundary-\(uniqueID)"
        parts = []
    }
}

extension NetSkeinMultipartFormBuilder {
    @discardableResult
    public func text(name: String, value: String) -> Self {
        let allocator = ByteBufferAllocator()
        var buffer = allocator.buffer(capacity: value.utf8.count)
        buffer.writeString(value)

        var copy = self
        copy.parts.append(
            NetSkeinMultipartForm.Part(name: name, filename: nil, contentType: nil, body: buffer)
        )
        return copy
    }

    @discardableResult
    public func file(
        name: String,
        filename: String,
        contentType: String,
        body: ByteBuffer
    ) -> Self {
        var copy = self
        copy.parts.append(
            NetSkeinMultipartForm.Part(
                name: name,
                filename: filename,
                contentType: contentType,
                body: body
            )
        )
        return copy
    }

    public func build() -> NetSkeinMultipartForm {
        NetSkeinMultipartForm(boundary: boundary, parts: parts)
    }
}
