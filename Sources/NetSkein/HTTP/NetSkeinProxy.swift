import AsyncHTTPClient
import NIOHTTP1

public struct NetSkeinProxy: Sendable {
    let underlyingProxy: HTTPClient.Configuration.Proxy
}

extension NetSkeinProxy {
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
