import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// A `multipart/form-data` body, for sending text fields and files together, as an HTML form
/// with a file input does.
///
/// Build one with ``builder()``, then attach it with ``NetSkeinRequest/multipart(_:)``:
///
/// ```swift
/// let form = MultipartForm.builder()
///     .text(name: "title", value: "Holiday")
///     .file(name: "photo", filename: "beach.jpg", contentType: "image/jpeg", body: photo)
///     .build()
///
/// try await client.post("https://api.example.com/photos")
///     .multipart(form)
///     .send()
/// ```
///
/// Parts are sent in the order you add them. The whole form is held in memory, so for one large
/// file, ``NetSkeinRequest/file(atPath:chunkSize:onProgress:)`` uses less memory.
///
/// Names and filenames are written into the part headers as given, so they must not contain
/// `"` or line breaks.
///
/// ## Topics
///
/// ### Building a Form
///
/// - ``builder()``
/// - ``Builder``
/// - ``init(boundary:parts:)``
///
/// ### Reading the Form
///
/// - ``Part``
/// - ``bytes()``
/// - ``estimatedLength``
public struct MultipartForm: Sendable {
    /// One field of a form: a text value or a file.
    public struct Part: Sendable {
        /// The field name, as in `<input name="photo">`.
        public let name: String
        /// The file's name as the server sees it, or `nil` for a text field.
        public let filename: String?
        /// The file's media type, such as `image/jpeg`, or `nil` for a text field.
        public let contentType: String?
        /// The field's value or the file's contents.
        public let body: ByteBuffer
    }

    /// Collects parts, then creates the ``MultipartForm``.
    ///
    /// Each method returns a changed copy, so you can chain them and finish with ``build()``.
    public struct Builder: Sendable {
        private let boundary: String
        private var parts: [MultipartForm.Part]

        /// Creates an empty builder with a random boundary.
        ///
        /// ``MultipartForm/builder()`` does the same and reads better in a chain.
        public init() {
            let uniqueID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            boundary = "NetSkeinBoundary-\(uniqueID)"
            parts = []
        }
    }

    /// Separates the parts, so it must not appear in any part's body.
    let boundary: String
    let parts: [Part]

    /// Creates a form from a boundary and parts.
    ///
    /// ``builder()`` is simpler: it picks a boundary that can't appear in your data.
    ///
    /// - Parameters:
    ///   - boundary: The line that separates parts. It must not appear in any part's body.
    ///   - parts: The parts, in the order they're sent.
    public init(
        boundary: String,
        parts: [Part]
    ) {
        self.boundary = boundary
        self.parts = parts
    }

    /// Returns a builder for adding parts, then creating the form with ``Builder/build()``.
    public static func builder() -> Builder { Builder() }
}

extension MultipartForm {
    /// The size of ``bytes()`` in bytes, computed without encoding the form.
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

    /// Encodes the form as the bytes of a `multipart/form-data` body.
    ///
    /// ``NetSkeinRequest/multipart(_:)`` calls this for you.
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

extension MultipartForm.Builder {
    /// Adds a text field.
    ///
    /// - Parameters:
    ///   - name: The field name.
    ///   - value: The field's value, sent as UTF-8.
    /// - Returns: A copy of the builder with the field added.
    @discardableResult
    public func text(name: String, value: String) -> Self {
        let allocator = ByteBufferAllocator()
        var buffer = allocator.buffer(capacity: value.utf8.count)
        buffer.writeString(value)

        var copy = self
        copy.parts.append(
            MultipartForm.Part(name: name, filename: nil, contentType: nil, body: buffer)
        )
        return copy
    }

    /// Adds a file.
    ///
    /// - Parameters:
    ///   - name: The field name.
    ///   - filename: The file's name as the server sees it, such as `beach.jpg`.
    ///   - contentType: The file's media type, such as `image/jpeg`.
    ///   - body: The file's contents.
    /// - Returns: A copy of the builder with the file added.
    @discardableResult
    public func file(
        name: String,
        filename: String,
        contentType: String,
        body: ByteBuffer
    ) -> Self {
        var copy = self
        copy.parts.append(
            MultipartForm.Part(
                name: name,
                filename: filename,
                contentType: contentType,
                body: body
            )
        )
        return copy
    }

    /// Creates the form with the parts added so far.
    public func build() -> MultipartForm {
        MultipartForm(boundary: boundary, parts: parts)
    }
}
