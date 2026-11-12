import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import Tracing

/// Sends HTTP requests and holds what they share: connections, default headers, retries,
/// caching and middleware.
///
/// Create one client with ``builder()`` and reuse it for the life of your app, since it keeps a
/// pool of connections open. Start each request with a method such as ``get(_:)`` or
/// ``post(_:)``, describe it with ``NetSkeinRequest``, then send it:
///
/// ```swift
/// let client = NetSkeinClient.builder()
///     .defaultHeaders(["Accept": "application/json"])
///     .build()
///
/// let user = try await client.get("https://api.example.com/users/42")
///     .send()
///     .validate()
///     .json(User.self)
/// ```
///
/// Call ``shutdown()`` when you no longer need the client, to close its connections.
///
/// ## Topics
///
/// ### Creating a Client
///
/// - ``builder()``
/// - ``init(defaultHeaders:retryPolicy:)``
/// - ``init(transport:defaultHeaders:cookieJar:cache:circuitBreaker:transportDecompresses:retryPolicy:callTimeout:attemptMiddlewares:callMiddlewares:tracer:logger:percentEncoder:)``
///
/// ### Starting a Request
///
/// - ``get(_:)``
/// - ``post(_:)``
/// - ``put(_:)``
/// - ``patch(_:)``
/// - ``delete(_:)``
/// - ``request(_:url:)``
///
/// ### Shutting Down
///
/// - ``shutdown()``
public final class NetSkeinClient: Sendable {
    package let transport: any HTTPTransport
    let defaultHeaders: HTTPHeaders
    let retryPolicy: RetryPolicy
    /// Middleware that runs for every attempt of every call.
    let attemptMiddlewares: [any HTTPMiddleware]
    /// Middleware that runs once per call, around all of its attempts.
    let callMiddlewares: [any HTTPMiddleware]
    let cache: HTTPCache?
    let circuitBreaker: CircuitBreaker?
    /// The default for ``NetSkeinRequest/callTimeout(_:)``. `nil` sets no limit.
    let callTimeout: TimeAmount?
    /// Whether the transport decompresses response bodies but keeps their `Content-Encoding`.
    let transportDecompresses: Bool
    let tracer: (any Tracer)?
    let logger: Logger
    let percentEncoder: PercentEncoder

    /// Creates a client with the default settings, plus default headers and a retry policy.
    ///
    /// Connections time out after 10 seconds, and reads and writes after 30. To change anything
    /// else, use ``builder()`` instead.
    ///
    /// - Parameters:
    ///   - defaultHeaders: Headers sent with every request (default: none). A request's own
    ///     ``NetSkeinRequest/header(_:_:)`` replaces a default with the same name.
    ///   - retryPolicy: How failed requests are retried (default: ``RetryPolicy/disabled``).
    ///     Requests can change it with ``NetSkeinRequest/retry(_:)``.
    public convenience init(
        defaultHeaders: HTTPHeaders = .init(),
        retryPolicy: RetryPolicy = .disabled
    ) {
        var configuration = HTTPClient.Configuration()
        configuration.timeout = HTTPClient.Configuration.Timeout(
            connect: .seconds(10),
            read: .seconds(30),
            write: .seconds(30)
        )
        let transport = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
        self.init(
            transport: transport,
            defaultHeaders: defaultHeaders,
            retryPolicy: retryPolicy,
            logger: Logger(label: LoggerLabel.identifier)
        )
    }

    /// Creates a client that sends requests through `transport`.
    ///
    /// Use this to send requests through your own `HTTPClient`, or through a fake transport in
    /// tests. In most apps, ``builder()`` is simpler: it creates the transport for you.
    ///
    /// Requests to failing servers are rejected as described by ``CircuitBreaker`` when
    /// `circuitBreaker` is set.
    ///
    /// Responses are cached as described by ``HTTPCache`` when `cache` is set. The transport must
    /// not decompress response bodies. Build the client with ``NetSkeinClientBuilder`` to combine
    /// caching with automatic decompression.
    ///
    /// - Parameters:
    ///   - transport: Sends the requests, such as an `HTTPClient` or a fake transport in tests.
    ///   - defaultHeaders: Headers sent with every request (default: none). A request's own
    ///     ``NetSkeinRequest/header(_:_:)`` replaces a default with the same name.
    ///   - cookieJar: Stores cookies that responses set and sends them back (default: `nil`).
    ///     `nil` keeps no cookies.
    ///   - cache: Caches responses (default: `nil`). `nil` caches nothing.
    ///   - circuitBreaker: Rejects requests to servers that keep failing (default: `nil`). `nil`
    ///     never rejects.
    ///   - transportDecompresses: Whether `transport` decompresses response bodies
    ///     (default: `false`). Set it to `true` when it does, so the cache stores bodies
    ///     correctly.
    ///   - retryPolicy: How failed requests are retried (default: ``RetryPolicy/disabled``).
    ///     Requests can change it with ``NetSkeinRequest/retry(_:)``.
    ///   - callTimeout: The limit for each whole call (default: `nil`). `nil` sets none. Requests
    ///     can change it with ``NetSkeinRequest/callTimeout(_:)``.
    ///   - attemptMiddlewares: Middleware that runs for every attempt, in order (default: none).
    ///     See ``MiddlewareScope``.
    ///   - callMiddlewares: Middleware that runs once per call, around all its attempts
    ///     (default: none).
    ///   - tracer: Reports a span for each request (default: the globally bootstrapped tracer).
    ///     `nil` turns tracing off.
    ///   - logger: The logger that requests write to.
    ///   - percentEncoder: Encodes ``NetSkeinRequest/form(_:)`` bodies
    ///     (default: ``PercentEncoder/default``).
    public init(
        transport: some HTTPTransport,
        defaultHeaders: HTTPHeaders = .init(),
        cookieJar: CookieJar? = nil,
        cache: HTTPCache? = nil,
        circuitBreaker: CircuitBreaker? = nil,
        transportDecompresses: Bool = false,
        retryPolicy: RetryPolicy = .disabled,
        callTimeout: TimeAmount? = nil,
        attemptMiddlewares: [any HTTPMiddleware] = [],
        callMiddlewares: [any HTTPMiddleware] = [],
        tracer: (any Tracer)? = InstrumentationSystem.tracer,
        logger: Logger,
        percentEncoder: PercentEncoder = .default,
    ) {
        self.transport = transport
        self.defaultHeaders = defaultHeaders
        self.retryPolicy = retryPolicy
        self.callTimeout = callTimeout
        self.attemptMiddlewares =
            (cookieJar.map { [CookieMiddleware(jar: $0)] } ?? []) + attemptMiddlewares
        self.callMiddlewares = callMiddlewares
        self.cache = cache
        self.circuitBreaker = circuitBreaker
        self.transportDecompresses = transportDecompresses
        self.tracer = tracer
        self.logger = logger
        self.percentEncoder = percentEncoder
    }

    /// Returns a builder for configuring a client, then creating it with
    /// ``NetSkeinClientBuilder/build()``.
    public static func builder() -> NetSkeinClientBuilder {
        NetSkeinClientBuilder()
    }
}

extension NetSkeinClient {
    /// Starts a `GET` request to `url`.
    ///
    /// The request can't have a body, so methods such as ``NetSkeinRequest/json(_:)`` don't
    /// compile on it. To send a body anyway, call ``NetSkeinRequest/dangerouslyAllowBody()``
    /// first.
    ///
    /// - Parameter url: The full URL, including the scheme, such as
    ///   `https://api.example.com/users`.
    /// - Returns: A request to describe further, then send.
    public func get(_ url: String) -> NetSkeinRequest<BodyForbidden> {
        NetSkeinRequest(client: self, method: .GET, url: url, percentEncoder: percentEncoder)
    }

    /// Starts a `POST` request to `url`, which can have a body.
    ///
    /// - Parameter url: The full URL, including the scheme, such as
    ///   `https://api.example.com/users`.
    /// - Returns: A request to describe further, then send.
    public func post(_ url: String) -> NetSkeinRequest<BodyAllowed> {
        NetSkeinRequest(client: self, method: .POST, url: url, percentEncoder: percentEncoder)
    }

    /// Starts a `PUT` request to `url`, which can have a body.
    ///
    /// - Parameter url: The full URL, including the scheme, such as
    ///   `https://api.example.com/users`.
    /// - Returns: A request to describe further, then send.
    public func put(_ url: String) -> NetSkeinRequest<BodyAllowed> {
        NetSkeinRequest(client: self, method: .PUT, url: url, percentEncoder: percentEncoder)
    }

    /// Starts a `PATCH` request to `url`, which can have a body.
    ///
    /// - Parameter url: The full URL, including the scheme, such as
    ///   `https://api.example.com/users`.
    /// - Returns: A request to describe further, then send.
    public func patch(_ url: String) -> NetSkeinRequest<BodyAllowed> {
        NetSkeinRequest(client: self, method: .PATCH, url: url, percentEncoder: percentEncoder)
    }

    /// Starts a `DELETE` request to `url`.
    ///
    /// The request can't have a body, so methods such as ``NetSkeinRequest/json(_:)`` don't
    /// compile on it. To send a body anyway, call ``NetSkeinRequest/dangerouslyAllowBody()``
    /// first.
    ///
    /// - Parameter url: The full URL, including the scheme, such as
    ///   `https://api.example.com/users`.
    /// - Returns: A request to describe further, then send.
    public func delete(_ url: String) -> NetSkeinRequest<BodyForbidden> {
        NetSkeinRequest(client: self, method: .DELETE, url: url, percentEncoder: percentEncoder)
    }

    /// Starts a request with any HTTP method, such as `HEAD` or `OPTIONS`.
    ///
    /// The request can have a body whatever the method, so check that the server expects one
    /// before you attach it.
    ///
    /// - Parameters:
    ///   - method: The HTTP method, such as `.HEAD` or `.OPTIONS`.
    ///   - url: The full URL, including the scheme, such as `https://api.example.com/users`.
    /// - Returns: A request to describe further, then send.
    public func request(
        _ method: HTTPMethod,
        url: String
    ) -> NetSkeinRequest<BodyAllowed> {
        NetSkeinRequest(
            client: self,
            method: method,
            url: url,
            percentEncoder: percentEncoder
        )
    }

    /// Closes the client's connections and releases its resources.
    ///
    /// Call it once, when you're done with the client. Requests sent afterwards fail. Wait for
    /// requests in flight to finish first.
    ///
    /// - Throws: A ``NetSkeinError`` of kind ``NetSkeinError/Kind/ioFailure`` when the
    ///   connections can't be closed cleanly.
    public func shutdown() async throws(NetSkeinError) {
        do {
            try await transport.shutdown()
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
