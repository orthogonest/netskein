import NIOCore

/// A read-only view of the request body, for middleware that needs to inspect it.
public enum RequestBodyDescription: Equatable, Sendable {
    /// The request has no body.
    case none
    /// The body is held in memory, such as one set with ``NetSkeinRequest/json(_:)``.
    case bytes(ByteBuffer)
    /// The body is streamed from the file at `path`, set with
    /// ``NetSkeinRequest/file(atPath:chunkSize:onProgress:)``.
    case file(path: String)
}
