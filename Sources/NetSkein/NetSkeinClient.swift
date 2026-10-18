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

    public static func builder() -> NetSkeinClientBuilder { NetSkeinClientBuilder() }
}

extension NetSkeinClient {
    public func get(_ url: String) -> RequestBuilder<GETRequest> {
        RequestBuilder<GETRequest>(client: self, method: .GET, url: url)
    }

    public func post(_ url: String) -> RequestBuilder<POSTRequest> {
        RequestBuilder<POSTRequest>(client: self, method: .POST, url: url)
    }

    public func put(_ url: String) -> RequestBuilder<PUTRequest> {
        RequestBuilder<PUTRequest>(client: self, method: .PUT, url: url)
    }

    public func patch(_ url: String) -> RequestBuilder<PATCHRequest> {
        RequestBuilder<PATCHRequest>(client: self, method: .PATCH, url: url)
    }

    public func delete(_ url: String) -> RequestBuilder<DELETERequest> {
        RequestBuilder<DELETERequest>(client: self, method: .DELETE, url: url)
    }

    public func shutdown() async throws(NetSkeinError) {
        do {
            try await underlyingClient.shutdown()
        } catch {
            logger.error(
                "Failed to safely shutdown NetSkein underlying HTTP client: \(error.localizedDescription)"
            )

            throw NetSkeinError.custom(
                kind: .ioFailure,
                message:
                    "Failed to release network client system resources and event loops cleanly.",
                underlyingError: error
            )
        }
    }
}

public struct NetSkeinClientBuilder: Sendable {
    private var connectTimeout: TimeAmount
    private var readTimeout: TimeAmount
    private var writeTimeout: TimeAmount
    private var defaultHeaders: HTTPHeaders
    private var eventLoopGroupProvider: HTTPClient.EventLoopGroupProvider
    private var proxy: NetSkeinProxy?
    private var redirectPolicy: NetSkeinRedirectPolicy
    private var automaticDecompression: Bool
    private var decompressionLimit: NIOHTTPDecompression.DecompressionLimit
    private var cookieJar: NetSkeinCookieJar?
    private var tlsConfiguration: TLSConfiguration?
    private var acceptInvalidCertificates: Bool
    private var logger: Logger

    public init() {
        connectTimeout = .seconds(10)
        readTimeout = .seconds(30)
        writeTimeout = .seconds(30)
        defaultHeaders = HTTPHeaders()
        eventLoopGroupProvider = .singleton
        redirectPolicy = .default
        automaticDecompression = true
        decompressionLimit = .size(10 * 1024 * 1024)
        acceptInvalidCertificates = false
        logger = Logger(label: Label.identifier)
    }
}

extension NetSkeinClientBuilder {
    @discardableResult
    public func connectTimeout(_ duration: TimeAmount) -> Self {
        var copy = self
        copy.connectTimeout = duration
        return copy
    }

    @discardableResult
    public func readTimeout(_ duration: TimeAmount) -> Self {
        var copy = self
        copy.readTimeout = duration
        return copy
    }

    @discardableResult
    public func writeTimeout(_ duration: TimeAmount) -> Self {
        var copy = self
        copy.writeTimeout = duration
        return copy
    }

    @discardableResult
    public func defaultHeaders(_ headers: HTTPHeaders) -> Self {
        var copy = self
        copy.defaultHeaders = headers
        return copy
    }

    @discardableResult
    public func eventLoopGroupProvider(
        _ provider: HTTPClient.EventLoopGroupProvider
    ) -> Self {
        var copy = self
        copy.eventLoopGroupProvider = provider
        return copy
    }

    @discardableResult
    public func proxy(_ proxy: NetSkeinProxy) -> Self {
        var copy = self
        copy.proxy = proxy
        return copy
    }

    @discardableResult
    public func redirectPolicy(_ policy: NetSkeinRedirectPolicy) -> Self {
        var copy = self
        copy.redirectPolicy = policy
        return copy
    }

    @discardableResult
    public func automaticDecompression(_ enabled: Bool) -> Self {
        var copy = self
        copy.automaticDecompression = enabled
        return copy
    }

    @discardableResult
    public func decompressionLimit(
        _ limit: NIOHTTPDecompression.DecompressionLimit
    ) -> Self {
        var copy = self
        copy.decompressionLimit = limit
        return copy
    }

    @discardableResult
    public func cookieStore(_ jar: NetSkeinCookieJar) -> Self {
        var copy = self
        copy.cookieJar = jar
        return copy
    }

    @discardableResult
    public func tlsConfiguration(_ configuration: TLSConfiguration) -> Self {
        var copy = self
        copy.tlsConfiguration = configuration
        return copy
    }

    @discardableResult
    public func acceptInvalidCertificates(_ accept: Bool) -> Self {
        var copy = self
        copy.acceptInvalidCertificates = accept
        return copy
    }

    @discardableResult
    public func logger(_ logger: Logger) -> Self {
        var copy = self
        copy.logger = logger
        return copy
    }

    public func build() -> NetSkeinClient {
        var config = HTTPClient.Configuration()

        config.timeout = HTTPClient.Configuration.Timeout(
            connect: connectTimeout,
            read: readTimeout,
            write: writeTimeout
        )

        if let proxy { config.proxy = proxy.underlyingProxy }

        config.redirectConfiguration = redirectPolicy.underlyingConfiguration

        var tlsConfig = tlsConfiguration ?? TLSConfiguration.makeClientConfiguration()
        if acceptInvalidCertificates { tlsConfig.certificateVerification = .none }
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
