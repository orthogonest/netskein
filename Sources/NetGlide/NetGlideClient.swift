import AsyncHTTPClient
import NIOHTTP1

public final class NetGlideClient: Sendable {
    let underlyingClient: HTTPClient
    let defaultHeaders: HTTPHeaders

    public init(
        eventLoopGroupProvider provider: HTTPClient.EventLoopGroupProvider = .singleton,
        configuration: HTTPClient.Configuration = .init(),
        defaultHeaders: HTTPHeaders = .init()
    ) {
        underlyingClient = HTTPClient(
            eventLoopGroupProvider: provider,
            configuration: configuration
        )
        self.defaultHeaders = defaultHeaders
    }
}

public extension NetGlideClient {
    func get(_ url: String) -> RequestBuilder {
        RequestBuilder(client: self, method: .GET, url: url)
    }

    func post(_ url: String) -> RequestBuilder {
        RequestBuilder(client: self, method: .POST, url: url)
    }

    func put(_ url: String) -> RequestBuilder {
        RequestBuilder(client: self, method: .PUT, url: url)
    }

    func patch(_ url: String) -> RequestBuilder {
        RequestBuilder(client: self, method: .PATCH, url: url)
    }

    func delete(_ url: String) -> RequestBuilder {
        RequestBuilder(client: self, method: .DELETE, url: url)
    }

    func shutdown() async throws {
        try await underlyingClient.shutdown()
    }
}
