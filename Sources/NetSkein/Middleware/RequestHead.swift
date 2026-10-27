import NIOHTTP1

/// The parts of an outgoing request that middleware can change.
///
/// The body is managed by NetSkein so it can be re-sent safely; middleware can inspect it
/// through ``MiddlewareContext/body``.
public struct RequestHead: Sendable {
    public var method: HTTPMethod
    public var url: String
    public var headers: HTTPHeaders

    public init(method: HTTPMethod, url: String, headers: HTTPHeaders) {
        self.method = method
        self.url = url
        self.headers = headers
    }
}
