import AsyncHTTPClient
import NIOHTTP1

public struct Proxy: Sendable {
    let underlyingProxy: HTTPClient.Configuration.Proxy
}

extension Proxy {
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

    public static func socks(host: String, port: Int = 1080) -> Self {
        .init(underlyingProxy: .socksServer(host: host, port: port))
    }
}
