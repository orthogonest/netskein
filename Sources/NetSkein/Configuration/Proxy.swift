import AsyncHTTPClient
import NIOHTTP1

/// A proxy server that a client sends its requests through.
///
/// Set with ``NetSkeinClientBuilder/proxy(_:)``.
public struct Proxy: Sendable {
    let underlyingProxy: HTTPClient.Configuration.Proxy
}

extension Proxy {
    /// An HTTP proxy at `host` and `port`.
    ///
    /// HTTPS requests reach the server through a tunnel opened with `CONNECT`, so the proxy
    /// can't read them.
    ///
    /// - Parameters:
    ///   - host: The proxy's host name or IP address.
    ///   - port: The proxy's port.
    ///   - authorization: Credentials for the proxy, sent in `Proxy-Authorization`
    ///     (default: `nil`, for none).
    ///   - connectHeaders: Extra headers for the proxy's `CONNECT` request (default: none).
    /// - Returns: The proxy, to pass to ``NetSkeinClientBuilder/proxy(_:)``.
    public static func http(
        host: String,
        port: Int,
        authorization: HTTPClient.Authorization? = nil,
        connectHeaders: HTTPHeaders = HTTPHeaders()
    ) -> Self {
        .init(
            underlyingProxy: .server(
                host: host,
                port: port,
                authorization: authorization,
                connectHeaders: connectHeaders
            )
        )
    }

    /// A SOCKS5 proxy at `host` and `port`.
    ///
    /// - Parameters:
    ///   - host: The proxy's host name or IP address.
    ///   - port: The proxy's port (default: 1080).
    /// - Returns: The proxy, to pass to ``NetSkeinClientBuilder/proxy(_:)``.
    public static func socks(host: String, port: Int = 1080) -> Self {
        .init(underlyingProxy: .socksServer(host: host, port: port))
    }
}
