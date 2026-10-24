import AsyncHTTPClient
import Logging
import NIOCore
import NIOHTTP1
import NIOHTTPCompression
import NIOSSL

public struct NetSkeinClientBuilder: Sendable {
    private var connectTimeout: TimeAmount
    private var readTimeout: TimeAmount
    private var writeTimeout: TimeAmount
    private var defaultHeaders: HTTPHeaders
    private var eventLoopGroupProvider: HTTPClient.EventLoopGroupProvider
    private var proxy: Proxy?
    private var redirectPolicy: RedirectPolicy
    private var automaticDecompression: Bool
    private var decompressionLimit: NIOHTTPDecompression.DecompressionLimit
    private var cookieJar: CookieJar?
    private var retryPolicy: RetryPolicy
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
        retryPolicy = .disabled
        acceptInvalidCertificates = false
        logger = Logger(label: LoggerLabel.identifier)
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
    public func proxy(_ proxy: Proxy) -> Self {
        var copy = self
        copy.proxy = proxy
        return copy
    }

    @discardableResult
    public func redirectPolicy(_ policy: RedirectPolicy) -> Self {
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
    public func cookieJar(_ jar: CookieJar) -> Self {
        var copy = self
        copy.cookieJar = jar
        return copy
    }

    @discardableResult
    public func retryPolicy(_ policy: RetryPolicy) -> Self {
        var copy = self
        copy.retryPolicy = policy
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
}

extension NetSkeinClientBuilder {
    public func build() -> NetSkeinClient<HTTPClient> {
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

        let transport = HTTPClient(
            eventLoopGroupProvider: eventLoopGroupProvider,
            configuration: config
        )

        return NetSkeinClient(
            transport: transport,
            defaultHeaders: defaultHeaders,
            cookieJar: cookieJar,
            retryPolicy: retryPolicy,
            logger: logger
        )
    }
}
