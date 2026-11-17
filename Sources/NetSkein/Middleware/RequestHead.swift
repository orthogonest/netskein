import NIOHTTP1

/// The parts of an outgoing request that middleware can change.
///
/// The body is managed by NetSkein so it can be re-sent safely. Middleware can inspect it
/// through ``MiddlewareContext/body``.
public struct RequestHead: Sendable {
    /// The HTTP method.
    public var method: HTTPMethod
    /// The full URL, including the scheme and query.
    public var url: String
    /// The headers to send.
    public var headers: HTTPHeaders

    /// Creates a request head, such as for testing a middleware on its own.
    ///
    /// - Parameters:
    ///   - method: The HTTP method.
    ///   - url: The full URL, including the scheme and query.
    ///   - headers: The headers to send.
    public init(method: HTTPMethod, url: String, headers: HTTPHeaders) {
        self.method = method
        self.url = url
        self.headers = headers
    }
}
