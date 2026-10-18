import NIOConcurrencyHelpers
import NIOCore

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public struct NetSkeinMultipartForm: Sendable {
    struct Part: Sendable {
        let name: String
        let filename: String?
        let contentType: String?
        let body: ByteBuffer
    }

    let boundary: String
    let parts: [Part]

    public static func builder() -> NetSkeinMultipartFormBuilder { NetSkeinMultipartFormBuilder() }
}

extension NetSkeinMultipartForm {
    public var estimatedLength: Int {
        var total = 0
        for part in parts {
            total += 4 + boundary.utf8.count  // "--" + boundary + "\r\n"
            total += 38 + part.name.utf8.count  // "Content-Disposition: form-data; \"...\"\r\n"
            if let filename = part.filename {
                total += 13 + filename.utf8.count  // "; filename=\"...\""
            }
            if let contentType = part.contentType {
                total += 16 + contentType.utf8.count  // "Content-Type: ...\r\n"
            }
            total += 2  // "\r\n" header dan body part separator
            total += part.body.readableBytes  // Payload part size
            total += 2  // "\r\n"
        }
        total += 6 + boundary.utf8.count  // "--" + boundary + "--\r\n"
        return total
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
    public mutating func text(name: String, value: String) -> Self {
        let allocator = ByteBufferAllocator()
        var buffer = allocator.buffer(capacity: value.utf8.count)
        buffer.writeString(value)
        parts.append(
            NetSkeinMultipartForm.Part(name: name, filename: nil, contentType: nil, body: buffer)
        )
        return self
    }

    @discardableResult
    public mutating func file(
        name: String,
        filename: String,
        contentType: String,
        body: ByteBuffer
    ) -> Self {
        parts.append(
            NetSkeinMultipartForm.Part(
                name: name,
                filename: filename,
                contentType: contentType,
                body: body
            )
        )
        return self
    }

    public mutating func build() -> NetSkeinMultipartForm {
        NetSkeinMultipartForm(boundary: boundary, parts: parts)
    }
}
