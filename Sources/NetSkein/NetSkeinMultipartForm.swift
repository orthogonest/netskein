import Foundation
import NIOCore

public struct NetSkeinMultipartForm: Sendable {
    struct Part {
        let name: String
        let filename: String?
        let contentType: String?
        let body: ByteBuffer
    }

    let boundary: String
    let parts: [Part]

    public static var builder: NetSkeinMultipartFormBuilder {
        NetSkeinMultipartFormBuilder()
    }
}

public extension NetSkeinMultipartForm {
    var estimatedLength: Int {
        var total = 0
        for part in parts {
            total += 4 + boundary.utf8.count // "--" + boundary + "\r\n"
            total += 38 + part.name.utf8.count // "Content-Disposition: form-data; name=\"...\"\r\n"
            if let filename = part.filename {
                total += 13 + filename.utf8.count // "; filename=\"...\""
            }
            if let contentType = part.contentType {
                total += 16 + contentType.utf8.count // "Content-Type: ...\r\n"
            }
            total += 2 // "\r\n" header dan body part separator
            total += part.body.readableBytes // Payload part size
            total += 2 // "\r\n"
        }
        total += 6 + boundary.utf8.count // "--" + boundary + "--\r\n"
        return total
    }
}

public final class NetSkeinMultipartFormBuilder {
    private let boundary: String
    private let mutex: Mutex
    private var parts: [NetSkeinMultipartForm.Part]

    public init() {
        boundary = "NetSkeinBoundary-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        mutex = Mutex()
        parts = []
    }
}

public extension NetSkeinMultipartFormBuilder {
    @discardableResult
    func text(name: String, value: String) -> Self {
        mutex.withLock {
            var buffer = ByteBufferAllocator().buffer(capacity: value.utf8.count)
            buffer.writeString(value)
            parts.append(NetSkeinMultipartForm.Part(
                name: name,
                filename: nil,
                contentType: nil,
                body: buffer
            ))
        }
        return self
    }

    @discardableResult
    func file(name: String, filename: String, contentType: String, body: ByteBuffer) -> Self {
        mutex.withLock {
            parts.append(NetSkeinMultipartForm.Part(
                name: name,
                filename: filename,
                contentType: contentType,
                body: body
            ))
        }
        return self
    }

    func build() -> NetSkeinMultipartForm {
        mutex.withLock {
            NetSkeinMultipartForm(boundary: boundary, parts: parts)
        }
    }
}
