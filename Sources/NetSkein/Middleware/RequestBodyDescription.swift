import NIOCore

/// A read-only view of the request body, for middleware that needs to inspect it.
public enum RequestBodyDescription: Equatable, Sendable {
    case none
    case bytes(ByteBuffer)
    case file(path: String)
}
