import AsyncHTTPClient

public struct NetSkeinProxy: Sendable {
    let underlyingProxy: HTTPClient.Configuration.Proxy
}

public extension NetSkeinProxy {
    static func http(host: String, port: Int) -> Self {
        .init(underlyingProxy: .server(host: host, port: port))
    }

    static func socks(host: String, port: Int) -> Self {
        .init(underlyingProxy: .socksServer(host: host, port: port))
    }
}
