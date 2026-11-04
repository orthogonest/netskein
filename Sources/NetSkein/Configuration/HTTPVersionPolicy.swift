import AsyncHTTPClient

/// Which HTTP versions the client may use to talk to a server.
///
/// Set with ``NetSkeinClientBuilder/httpVersion(_:)``.
@nonexhaustive
public enum HTTPVersionPolicy: Sendable, Hashable {
    /// HTTP/2 when the server offers it over HTTPS, HTTP/1.1 otherwise. The default.
    ///
    /// The version is negotiated during the TLS handshake (ALPN), so plain `http://` URLs
    /// always use HTTP/1.1.
    case automatic

    /// HTTP/1.1 only, even when the server supports HTTP/2.
    ///
    /// Useful for servers or proxies that handle HTTP/2 badly, or to compare behavior between
    /// versions. Each request in flight to a host then needs its own connection.
    case http1Only
}

extension HTTPVersionPolicy {
    var underlyingVersion: HTTPClient.Configuration.HTTPVersion {
        switch self {
        case .automatic: .automatic
        case .http1Only: .http1Only
        }
    }
}
