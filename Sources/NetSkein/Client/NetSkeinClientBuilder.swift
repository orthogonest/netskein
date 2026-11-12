import AsyncHTTPClient
import Logging
import NIOCore
import NIOHTTP1
import NIOHTTPCompression
import NIOSSL
import Tracing

/// Configures a ``NetSkeinClient`` step by step, then creates it.
///
/// Each method returns a changed copy, so you can chain them and stop at ``build()``:
///
/// ```swift
/// let client = NetSkeinClient.builder()
///     .connectTimeout(.seconds(5))
///     .defaultHeaders(["User-Agent": "MyApp/1.0"])
///     .retryPolicy(.standard())
///     .build()
/// ```
///
/// Settings you don't change keep the defaults listed on each method.
///
/// ## Topics
///
/// ### Creating the Client
///
/// - ``init()``
/// - ``build()``
///
/// ### Timeouts
///
/// - ``connectTimeout(_:)``
/// - ``readTimeout(_:)``
/// - ``writeTimeout(_:)``
/// - ``callTimeout(_:)``
///
/// ### Headers and Cookies
///
/// - ``defaultHeaders(_:)``
/// - ``cookieJar(_:)``
///
/// ### Connections
///
/// - ``proxy(_:)``
/// - ``redirectPolicy(_:)``
/// - ``httpVersion(_:)``
/// - ``eventLoopGroupProvider(_:)``
///
/// ### Security
///
/// - ``tlsConfiguration(_:)``
/// - ``acceptInvalidCertificates(_:)``
///
/// ### Response Decompression
///
/// - ``automaticDecompression(_:)``
/// - ``decompressionLimit(_:)``
///
/// ### Resilience
///
/// - ``retryPolicy(_:)``
/// - ``circuitBreaker(_:)``
/// - ``cache(_:)``
///
/// ### Middleware
///
/// - ``using(_:per:)``
/// - ``using(per:_:)``
///
/// ### Logging and Tracing
///
/// - ``logger(_:)``
/// - ``tracer(_:)``
/// - ``disableTracing()``
public struct NetSkeinClientBuilder: Sendable {
    /// Which tracer ``build()`` gives the client.
    private enum TracerSelection: Sendable {
        /// The globally bootstrapped tracer, read when the client is built.
        case global
        case custom(any Tracer)
        /// No tracer: no spans and no trace headers.
        case disabled
    }

    private var connectTimeout: TimeAmount
    private var readTimeout: TimeAmount
    private var writeTimeout: TimeAmount
    private var defaultHeaders: HTTPHeaders
    private var eventLoopGroupProvider: HTTPClient.EventLoopGroupProvider
    private var proxy: Proxy?
    private var redirectPolicy: RedirectPolicy
    private var httpVersion: HTTPVersionPolicy
    private var automaticDecompression: Bool
    private var decompressionLimit: NIOHTTPDecompression.DecompressionLimit
    private var cookieJar: CookieJar?
    private var cache: HTTPCache?
    private var circuitBreaker: CircuitBreaker?
    private var retryPolicy: RetryPolicy
    /// `nil` sets no limit.
    private var callTimeout: TimeAmount?
    private var attemptMiddlewares: [any HTTPMiddleware]
    private var callMiddlewares: [any HTTPMiddleware]
    private var tlsConfiguration: TLSConfiguration?
    private var acceptInvalidCertificates: Bool
    private var tracer: TracerSelection
    private var logger: Logger

    /// Creates a builder with the default settings.
    ///
    /// ``NetSkeinClient/builder()`` does the same and reads better in a chain.
    public init() {
        connectTimeout = .seconds(10)
        readTimeout = .seconds(30)
        writeTimeout = .seconds(30)
        defaultHeaders = HTTPHeaders()
        eventLoopGroupProvider = .singleton
        redirectPolicy = .default
        httpVersion = .automatic
        automaticDecompression = true
        decompressionLimit = .size(10 * 1024 * 1024)
        retryPolicy = .disabled
        attemptMiddlewares = []
        callMiddlewares = []
        acceptInvalidCertificates = false
        tracer = .global
        logger = Logger(label: LoggerLabel.identifier)
    }
}

extension NetSkeinClientBuilder {
    /// Limits how long opening a connection to a server can take (default: 10 seconds).
    ///
    /// - Parameter duration: The longest a connection can take to open.
    /// - Returns: A copy of the builder with the new connect timeout.
    @discardableResult
    public func connectTimeout(_ duration: TimeAmount) -> Self {
        var copy = self
        copy.connectTimeout = duration
        return copy
    }

    /// Limits how long the client waits for the next piece of a response (default: 30 seconds).
    ///
    /// The wait starts over each time data arrives, so a large response that keeps arriving never
    /// hits it. To limit a whole request, use ``callTimeout(_:)``.
    ///
    /// - Parameter duration: The longest wait for the next piece of a response.
    /// - Returns: A copy of the builder with the new read timeout.
    @discardableResult
    public func readTimeout(_ duration: TimeAmount) -> Self {
        var copy = self
        copy.readTimeout = duration
        return copy
    }

    /// Limits how long the client waits to send the next piece of a request
    /// (default: 30 seconds).
    ///
    /// - Parameter duration: The longest wait to send the next piece of a request.
    /// - Returns: A copy of the builder with the new write timeout.
    @discardableResult
    public func writeTimeout(_ duration: TimeAmount) -> Self {
        var copy = self
        copy.writeTimeout = duration
        return copy
    }

    /// Sets headers to send with every request, such as `User-Agent` or `Accept`.
    ///
    /// A request's own ``NetSkeinRequest/header(_:_:)`` replaces a default with the same name.
    /// Calling this again replaces the headers set before.
    ///
    /// - Parameter headers: The headers to send with every request.
    /// - Returns: A copy of the builder with these default headers.
    @discardableResult
    public func defaultHeaders(_ headers: HTTPHeaders) -> Self {
        var copy = self
        copy.defaultHeaders = headers
        return copy
    }

    /// Sets the SwiftNIO event loops the client runs on (default: the shared singleton group).
    ///
    /// Most apps don't need this. Pass `.shared(group)` to run on event loops your server already
    /// owns.
    ///
    /// - Parameter provider: The event loops to run on: `.singleton`, or `.shared(group)`.
    /// - Returns: A copy of the builder with this event loop provider.
    @discardableResult
    public func eventLoopGroupProvider(
        _ provider: HTTPClient.EventLoopGroupProvider
    ) -> Self {
        var copy = self
        copy.eventLoopGroupProvider = provider
        return copy
    }

    /// Sends every request through a proxy server (default: none, so requests connect directly).
    ///
    /// - Parameter proxy: The proxy to send requests through.
    /// - Returns: A copy of the builder with this proxy.
    @discardableResult
    public func proxy(_ proxy: Proxy) -> Self {
        var copy = self
        copy.proxy = proxy
        return copy
    }

    /// Sets whether and how often redirects are followed (default: ``RedirectPolicy/default``).
    ///
    /// - Parameter policy: Whether and how often to follow redirects.
    /// - Returns: A copy of the builder with this redirect policy.
    @discardableResult
    public func redirectPolicy(_ policy: RedirectPolicy) -> Self {
        var copy = self
        copy.redirectPolicy = policy
        return copy
    }

    /// Sets which HTTP versions the client may use (default: ``HTTPVersionPolicy/automatic``).
    ///
    /// - Parameter policy: Which HTTP versions the client may use.
    /// - Returns: A copy of the builder with this HTTP version policy.
    @discardableResult
    public func httpVersion(_ policy: HTTPVersionPolicy) -> Self {
        var copy = self
        copy.httpVersion = policy
        return copy
    }

    /// Sets whether compressed responses (`gzip` or `deflate`) are decompressed for you
    /// (default: `true`).
    ///
    /// Turn it off to receive the bytes exactly as the server sent them. See
    /// ``decompressionLimit(_:)`` for the size limit applied while decompressing.
    ///
    /// - Parameter enabled: Whether to decompress responses for you.
    /// - Returns: A copy of the builder with decompression turned on or off.
    @discardableResult
    public func automaticDecompression(_ enabled: Bool) -> Self {
        var copy = self
        copy.automaticDecompression = enabled
        return copy
    }

    /// Limits how large a response may grow when decompressed (default: 10 MiB).
    ///
    /// A response that decompresses to more fails instead, so a small compressed response can't
    /// expand into gigabytes in memory. Has no effect when ``automaticDecompression(_:)`` is off.
    ///
    /// - Parameter limit: The largest size a response may decompress to, such as
    ///   `.size(50 * 1024 * 1024)`, or `.none` for no limit.
    /// - Returns: A copy of the builder with this decompression limit.
    @discardableResult
    public func decompressionLimit(
        _ limit: NIOHTTPDecompression.DecompressionLimit
    ) -> Self {
        var copy = self
        copy.decompressionLimit = limit
        return copy
    }

    /// Stores cookies that servers set, and sends them back on later requests to the same host.
    ///
    /// Without a jar, cookies are neither stored nor sent. See ``CookieJar`` for what it keeps.
    ///
    /// - Parameter jar: The jar that stores and sends cookies.
    /// - Returns: A copy of the builder with this cookie jar.
    @discardableResult
    public func cookieJar(_ jar: CookieJar) -> Self {
        var copy = self
        copy.cookieJar = jar
        return copy
    }

    /// Caches responses as described by ``HTTPCache``.
    ///
    /// - Parameter cache: The cache that stores and reuses responses.
    /// - Returns: A copy of the builder with this cache.
    @discardableResult
    public func cache(_ cache: HTTPCache) -> Self {
        var copy = self
        copy.cache = cache
        return copy
    }

    /// Rejects requests to servers that keep failing, as described by ``CircuitBreaker``.
    ///
    /// - Parameter breaker: The circuit breaker that tracks failing servers.
    /// - Returns: A copy of the builder with this circuit breaker.
    @discardableResult
    public func circuitBreaker(_ breaker: CircuitBreaker) -> Self {
        var copy = self
        copy.circuitBreaker = breaker
        return copy
    }

    /// Sets how failed requests are retried (default: ``RetryPolicy/disabled``).
    ///
    /// A request can change it with ``NetSkeinRequest/retry(_:)``.
    ///
    /// - Parameter policy: How failed requests are retried.
    /// - Returns: A copy of the builder with this retry policy.
    @discardableResult
    public func retryPolicy(_ policy: RetryPolicy) -> Self {
        var copy = self
        copy.retryPolicy = policy
        return copy
    }

    /// Limits every call made by the built client, attempts and waits included. Requests can
    /// change it with ``NetSkeinRequest/callTimeout(_:)``. Calls have no overall limit unless this is set.
    ///
    /// - Parameter duration: The longest a whole call can take, attempts and waits included.
    /// - Returns: A copy of the builder with the new call timeout.
    @discardableResult
    public func callTimeout(_ duration: TimeAmount) -> Self {
        var copy = self
        copy.callTimeout = duration
        return copy
    }

    /// Adds a middleware that runs for every call sent by the built client: once per call, or
    /// for every attempt, as `scope` says. See ``MiddlewareScope``.
    ///
    /// - Parameters:
    ///   - middleware: The middleware to add. It runs after the ones added before it.
    ///   - scope: Whether it runs once per call or for every attempt
    ///     (default: ``MiddlewareScope/attempt``).
    /// - Returns: A copy of the builder with the middleware added.
    @discardableResult
    public func using(
        _ middleware: some HTTPMiddleware,
        per scope: MiddlewareScope = .attempt
    ) -> Self {
        var copy = self
        switch scope {
        case .call: copy.callMiddlewares.append(middleware)
        case .attempt: copy.attemptMiddlewares.append(middleware)
        }
        return copy
    }

    /// Adds a closure as a middleware that runs for every call sent by the built client: once
    /// per call, or for every attempt, as `scope` says. See ``MiddlewareScope``.
    ///
    /// - Parameters:
    ///   - scope: Whether it runs once per call or for every attempt
    ///     (default: ``MiddlewareScope/attempt``).
    ///   - intercept: Called with the request, its context, and `next`, which sends the request
    ///     on. Return the response from `next`, or one of your own.
    /// - Returns: A copy of the builder with the middleware added.
    @discardableResult
    public func using(
        per scope: MiddlewareScope = .attempt,
        _ intercept:
            @escaping @Sendable (
                RequestHead,
                MiddlewareContext,
                HTTPMiddleware.Next
            ) async throws -> HTTPClientResponse
    ) -> Self {
        using(ClosureMiddleware(intercept), per: scope)
    }

    /// Sets the TLS configuration used for HTTPS, such as trusted root certificates or a client
    /// certificate (default: the system's trusted certificates).
    ///
    /// - Parameter configuration: The TLS settings for HTTPS connections.
    /// - Returns: A copy of the builder with this TLS configuration.
    @discardableResult
    public func tlsConfiguration(_ configuration: TLSConfiguration) -> Self {
        var copy = self
        copy.tlsConfiguration = configuration
        return copy
    }

    /// Turns off certificate verification for HTTPS when `accept` is `true` (default: `false`).
    ///
    /// - Warning: Anyone between the client and the server can then read and change its traffic.
    ///   Use it only against local test servers with self-signed certificates, never in production.
    /// - Parameter accept: Whether to skip certificate verification.
    /// - Returns: A copy of the builder with certificate verification turned off or on.
    @discardableResult
    public func acceptInvalidCertificates(_ accept: Bool) -> Self {
        var copy = self
        copy.acceptInvalidCertificates = accept
        return copy
    }

    /// Reports request spans to `tracer` instead of the globally bootstrapped tracer.
    ///
    /// - Parameter tracer: The tracer that receives request spans.
    /// - Returns: A copy of the builder with this tracer.
    @discardableResult
    public func tracer(_ tracer: any Tracer) -> Self {
        var copy = self
        copy.tracer = .custom(tracer)
        return copy
    }

    /// Stops the built client from creating spans or sending trace headers, even when a global
    /// tracer is bootstrapped.
    @discardableResult
    public func disableTracing() -> Self {
        var copy = self
        copy.tracer = .disabled
        return copy
    }

    /// Sets the logger that requests write to (default: a logger labeled
    /// `com.netskein.network`).
    ///
    /// - Parameter logger: The logger that requests write to.
    /// - Returns: A copy of the builder with this logger.
    @discardableResult
    public func logger(_ logger: Logger) -> Self {
        var copy = self
        copy.logger = logger
        return copy
    }
}

extension NetSkeinClientBuilder {
    /// Creates a client with the settings so far.
    ///
    /// Each call creates a new client with its own connections. Call
    /// ``NetSkeinClient/shutdown()`` on each one when you're done with it.
    public func build() -> NetSkeinClient {
        var config = HTTPClient.Configuration()

        config.timeout = HTTPClient.Configuration.Timeout(
            connect: connectTimeout,
            read: readTimeout,
            write: writeTimeout
        )

        if let proxy { config.proxy = proxy.underlyingProxy }

        config.redirectConfiguration = redirectPolicy.underlyingConfiguration
        config.httpVersion = httpVersion.underlyingVersion

        var tlsConfig = tlsConfiguration ?? TLSConfiguration.makeClientConfiguration()
        if acceptInvalidCertificates { tlsConfig.certificateVerification = .none }
        config.tlsConfiguration = tlsConfig

        if automaticDecompression {
            config.decompression = .enabled(limit: decompressionLimit)
        } else {
            config.decompression = .disabled
        }

        let resolvedTracer: (any Tracer)? =
            switch tracer {
            case .global: InstrumentationSystem.tracer
            case let .custom(tracer): tracer
            case .disabled: nil
            }
        config.tracing.tracer = resolvedTracer

        let transport = HTTPClient(
            eventLoopGroupProvider: eventLoopGroupProvider,
            configuration: config
        )

        return NetSkeinClient(
            transport: transport,
            defaultHeaders: defaultHeaders,
            cookieJar: cookieJar,
            cache: cache,
            circuitBreaker: circuitBreaker,
            transportDecompresses: automaticDecompression,
            retryPolicy: retryPolicy,
            callTimeout: callTimeout,
            attemptMiddlewares: attemptMiddlewares,
            callMiddlewares: callMiddlewares,
            tracer: resolvedTracer,
            logger: logger
        )
    }
}
