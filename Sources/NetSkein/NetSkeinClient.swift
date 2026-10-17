import AsyncHTTPClient
import Logging
import NIOCore
import NIOHTTP1
import NIOHTTPCompression
import NIOSSL

public final class NetSkeinClient: Sendable {
    let underlyingClient: HTTPClient
    let defaultHeaders: HTTPHeaders
    let cookieJar: NetSkeinCookieJar?
    let logger: Logger

    public init(
        underlyingClient: HTTPClient,
        defaultHeaders: HTTPHeaders = .init(),
        cookieJar: NetSkeinCookieJar? = nil,
        logger: Logger = Logger(label: Label.identifier)
    ) {
        self.underlyingClient = underlyingClient
        self.defaultHeaders = defaultHeaders
        self.cookieJar = cookieJar
        self.logger = logger
    }

    public convenience init(defaultHeaders: HTTPHeaders = .init()) {
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: .init())
        self.init(underlyingClient: client, defaultHeaders: defaultHeaders)
    }

    public static func builder() -> NetSkeinClientBuilder {
        NetSkeinClientBuilder()
    }
}

public extension NetSkeinClient {
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

public final class NetSkeinClientBuilder {
    private var connectTimeout: TimeAmount?
    private var readTimeout: TimeAmount?
    private var defaultHeaders: HTTPHeaders = .init()
    private var eventLoopGroupProvider: HTTPClient.EventLoopGroupProvider = .singleton
    private var proxy: NetSkeinProxy?
    private var redirectPolicy: NetSkeinRedirectPolicy = .default
    private var automaticDecompression: Bool = true
    private var decompressionLimit: NIOHTTPDecompression.DecompressionLimit = .size(10 * 1024 * 1024)
    private var cookieJar: NetSkeinCookieJar?
    private var tlsConfiguration: TLSConfiguration?
    private var acceptInvalidCertificates: Bool = false
    private var logger: Logger = .init(label: Label.identifier)

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
    public func proxy(_ proxy: NetSkeinProxy) -> Self {
        self.proxy = proxy
        return self
    }

    @discardableResult
    public func redirectPolicy(_ policy: NetSkeinRedirectPolicy) -> Self {
        redirectPolicy = policy
        return self
    }

    @discardableResult
    public func automaticDecompression(_ enabled: Bool) -> Self {
        automaticDecompression = enabled
        return self
    }

    @discardableResult
    public func decompressionLimit(_ limit: NIOHTTPDecompression.DecompressionLimit) -> Self {
        decompressionLimit = limit
        return self
    }

    @discardableResult
    public func cookieStore(_ jar: NetSkeinCookieJar) -> Self {
        cookieJar = jar
        return self
    }

    @discardableResult
    public func tlsConfiguration(_ configuration: TLSConfiguration) -> Self {
        tlsConfiguration = configuration
        return self
    }

    @discardableResult
    public func acceptInvalidCertificates(_ accept: Bool) -> Self {
        acceptInvalidCertificates = accept
        return self
    }

    @discardableResult
    public func logger(_ logger: Logger) -> Self {
        self.logger = logger
        return self
    }

    public func build() -> NetSkeinClient {
        var config = HTTPClient.Configuration()

        config.timeout = HTTPClient.Configuration.Timeout(
            connect: connectTimeout,
            read: readTimeout
        )

        if let proxy {
            config.proxy = proxy.underlyingProxy
        }

        config.redirectConfiguration = redirectPolicy.underlyingConfiguration

        var tlsConfig = tlsConfiguration ?? TLSConfiguration.makeClientConfiguration()
        if acceptInvalidCertificates {
            tlsConfig.certificateVerification = .none
        }
        config.tlsConfiguration = tlsConfig

        if automaticDecompression {
            config.decompression = .enabled(limit: decompressionLimit)
        } else {
            config.decompression = .disabled
        }

        let client = HTTPClient(
            eventLoopGroupProvider: eventLoopGroupProvider,
            configuration: config
        )

        return NetSkeinClient(
            underlyingClient: client,
            defaultHeaders: defaultHeaders,
            cookieJar: cookieJar,
            logger: logger
        )
    }
}
