import AsyncHTTPClient

public struct NetSkeinProxy: Sendable { let underlyingProxy: HTTPClient.Configuration.Proxy }

extension NetSkeinProxy {
    public static func http(host: String, port: Int) -> Self {
        .init(underlyingProxy: .server(host: host, port: port))
    }

    public static func socks(host: String, port: Int) -> Self {
        .init(underlyingProxy: .socksServer(host: host, port: port))
    }
}
