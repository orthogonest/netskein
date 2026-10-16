import AsyncHTTPClient
import NIOCore
import NIOHTTP1

public final class NetGlideClient: Sendable {
    let underlyingClient: HTTPClient
    let defaultHeaders: HTTPHeaders

    public init(
        underlyingClient: HTTPClient,
        defaultHeaders: HTTPHeaders = .init()
    ) {
        self.underlyingClient = underlyingClient
        self.defaultHeaders = defaultHeaders
    }

    public convenience init(defaultHeaders: HTTPHeaders = .init()) {
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: .init())
        self.init(underlyingClient: client, defaultHeaders: defaultHeaders)
    }

    public static func builder() -> NetGlideClientBuilder {
        NetGlideClientBuilder()
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

public final class NetGlideClientBuilder {
    private var connectTimeout: TimeAmount?
    private var readTimeout: TimeAmount?
    private var defaultHeaders: HTTPHeaders = .init()
    private var eventLoopGroupProvider: HTTPClient.EventLoopGroupProvider = .singleton
    private var proxy: NetGlideProxy?
    private var redirectPolicy: NetGlideRedirectPolicy = .default

    public init() {}

    @discardableResult
    public func connectTimeout(_ duration: TimeAmount) -> Self {
        connectTimeout = duration
        return self
    }

    @discardableResult
    public func readTimeout(_ duration: TimeAmount) -> Self {
        readTimeout = duration
        return self
    }

    @discardableResult
    public func defaultHeaders(_ headers: HTTPHeaders) -> Self {
        defaultHeaders = headers
        return self
    }

    @discardableResult
    public func eventLoopGroupProvider(_ provider: HTTPClient.EventLoopGroupProvider) -> Self {
        eventLoopGroupProvider = provider
        return self
    }

    @discardableResult
    public func proxy(_ proxy: NetGlideProxy) -> Self {
        self.proxy = proxy
        return self
    }

    @discardableResult
    public func redirectPolicy(_ policy: NetGlideRedirectPolicy) -> Self {
        redirectPolicy = policy
        return self
    }

    public func build() -> NetGlideClient {
        var config = HTTPClient.Configuration()

        let timeoutConfig = HTTPClient.Configuration.Timeout(
            connect: connectTimeout,
            read: readTimeout
        )
        config.timeout = timeoutConfig

        if let proxy {
            config.proxy = proxy.underlyingProxy
        }

        config.redirectConfiguration = redirectPolicy.underlyingConfiguration

        let client = HTTPClient(
            eventLoopGroupProvider: eventLoopGroupProvider,
            configuration: config
        )

        return NetGlideClient(
            underlyingClient: client,
            defaultHeaders: defaultHeaders
        )
    }
}
