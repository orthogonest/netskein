import AsyncHTTPClient
import Logging
import NIOCore
import NIOHTTP1
import NetSkein
import Tracing

/// Builds a `NetSkeinClient` whose requests are answered by ``HTTPStub``s through a
/// ``MockHTTPClient`` instead of the network.
///
/// Start one with ``NetSkein/NetSkeinClient/testing()``. It offers the options of
/// `NetSkeinClientBuilder` that matter without a network: default headers, cookies, cache,
/// circuit breaker, retry policy, call timeout, middleware, tracer and logger. Connection
/// settings such as timeouts, TLS, proxies, redirects and decompression belong to the
/// network, so they are left out.
///
/// Its defaults match the production builder, so code behaves the same in tests as in the app:
/// in particular, requests are not retried unless a test sets ``retryPolicy(_:)``.
///
/// ## Topics
///
/// ### Creating a Builder
///
/// - ``init()``
///
/// ### Adding Stubs
///
/// - ``addStub(_:)``
/// - ``addStubs(_:)``
///
/// ### Configuring the Client
///
/// - ``defaultHeaders(_:)``
/// - ``cookieJar(_:)``
/// - ``cache(_:)``
/// - ``circuitBreaker(_:)``
/// - ``retryPolicy(_:)``
/// - ``callTimeout(_:)``
/// - ``using(_:per:)``
/// - ``using(per:_:)``
///
/// ### Observing the Client
///
/// - ``tracer(_:)``
/// - ``disableTracing()``
/// - ``logger(_:)``
/// - ``onShutdown(_:)``
///
/// ### Building the Client
///
/// - ``build()``
public struct TestClientBuilder: Sendable {
    private var defaultHeaders: HTTPHeaders
    private var cookieJar: CookieJar?
    private var cache: HTTPCache?
    private var circuitBreaker: CircuitBreaker?
    private var retryPolicy: RetryPolicy
    private var callTimeout: TimeAmount?
    private var attemptMiddlewares: [any HTTPMiddleware]
    private var callMiddlewares: [any HTTPMiddleware]
    private var tracer: (any Tracer)?
    private var logger: Logger
    private var stubs: [HTTPStub]
    private var onShutdown: (@Sendable () async throws -> Void)?

    /// Creates a builder with no stubs and the default settings.
    ///
    /// ``NetSkein/NetSkeinClient/testing()`` does the same and reads better in a chain.
    public init() {
        self.stubs = []
        defaultHeaders = HTTPHeaders()
        retryPolicy = .disabled
        attemptMiddlewares = []
        callMiddlewares = []
        tracer = InstrumentationSystem.tracer
        logger = Logger(label: LoggerLabel.test)
    }
}

extension TestClientBuilder {
    /// Sets headers to send with every request, such as `User-Agent` or `Accept`.
    ///
    /// A request's own header replaces a default with the same name. Calling this again
    /// replaces the headers set before.
    ///
    /// - Parameter headers: The headers to send with every request.
    /// - Returns: A copy of the builder with these default headers.
    @discardableResult
    public func defaultHeaders(_ headers: HTTPHeaders) -> Self {
        var copy = self
        copy.defaultHeaders = headers
        return copy
    }

    /// Stores cookies that stubs set, and sends them back on later requests to the same host.
    ///
    /// Without a jar, cookies are neither stored nor sent.
    ///
    /// - Parameter jar: The jar that stores and sends cookies.
    /// - Returns: A copy of the builder with this cookie jar.
    @discardableResult
    public func cookieJar(_ jar: CookieJar) -> Self {
        var copy = self
        copy.cookieJar = jar
        return copy
    }

    /// Caches responses as described by `HTTPCache`.
    ///
    /// Use ``NetSkein/HTTPCache/testing(clock:storage:maxEntryBytes:defaultTTL:maxStaleOnError:defaultPolicy:)``
    /// to control the cache's clock. See <doc:TestingTheCache>.
    ///
    /// - Parameter cache: The cache to use.
    /// - Returns: A copy of the builder with this cache.
    @discardableResult
    public func cache(_ cache: HTTPCache) -> Self {
        var copy = self
        copy.cache = cache
        return copy
    }

    /// Rejects requests to servers that keep failing, as described by `CircuitBreaker`.
    ///
    /// Use ``NetSkein/CircuitBreaker/testing(clock:failureThreshold:openDuration:halfOpenMaxRequests:key:isFailure:)``
    /// to end an open period without waiting.
    ///
    /// - Parameter breaker: The circuit breaker to use.
    /// - Returns: A copy of the builder with this circuit breaker.
    @discardableResult
    public func circuitBreaker(_ breaker: CircuitBreaker) -> Self {
        var copy = self
        copy.circuitBreaker = breaker
        return copy
    }

    /// Sets how failed requests are retried (default: `RetryPolicy.disabled`).
    ///
    /// Use a backoff of `.immediate` so retries don't slow the test down.
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
    /// change it with `NetSkeinRequest.callTimeout(_:)`. Calls have no overall limit unless
    /// this is set.
    ///
    /// Combine it with ``HTTPStub/delay(_:)`` to test what happens when a call times out.
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
    /// for every attempt, as `scope` says.
    ///
    /// - Parameters:
    ///   - middleware: The middleware to add. It runs after the ones added before it.
    ///   - scope: Whether it runs once per call or for every attempt (default: `.attempt`).
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
    /// per call, or for every attempt, as `scope` says.
    ///
    /// - Parameters:
    ///   - scope: Whether it runs once per call or for every attempt (default: `.attempt`).
    ///   - intercept: Called with the request, its context, and `next`, which sends the request
    ///     on. Return the response from `next`, or one of your own.
    /// - Returns: A copy of the builder with the middleware added.
    @discardableResult
    public func using(
        per scope: MiddlewareScope = .attempt,
        _ intercept:
            @escaping @Sendable (RequestHead, MiddlewareContext, HTTPMiddleware.Next)
            async throws -> HTTPClientResponse
    ) -> Self {
        using(ClosureMiddleware(intercept), per: scope)
    }

    /// Records request spans in `tracer`, for example an `InMemoryTracer` that tests can inspect.
    ///
    /// Without this, spans go to the globally bootstrapped tracer, as read when the builder is
    /// created.
    ///
    /// - Parameter tracer: The tracer that receives request spans.
    /// - Returns: A copy of the builder with this tracer.
    @discardableResult
    public func tracer(_ tracer: any Tracer) -> Self {
        var copy = self
        copy.tracer = tracer
        return copy
    }

    /// Stops the built client from creating spans or sending trace headers, even when a global
    /// tracer is bootstrapped.
    ///
    /// - Returns: A copy of the builder with tracing turned off.
    @discardableResult
    public func disableTracing() -> Self {
        var copy = self
        copy.tracer = nil
        return copy
    }

    /// Sets the logger that requests write to (default: a logger labeled `com.netskein.test`).
    ///
    /// - Parameter logger: The logger that requests write to.
    /// - Returns: A copy of the builder with this logger.
    @discardableResult
    public func logger(_ logger: Logger) -> Self {
        var copy = self
        copy.logger = logger
        return copy
    }

    /// Adds stubs after the ones added before.
    ///
    /// Stubs for the same route answer successive calls in the order they were added. See
    /// ``MockHTTPClient``.
    ///
    /// - Parameter stubs: The stubs to add, in order.
    /// - Returns: A copy of the builder with the stubs added.
    @discardableResult
    public func addStubs(_ stubs: [HTTPStub]) -> Self {
        var copy = self
        copy.stubs.append(contentsOf: stubs)
        return copy
    }

    /// Adds a stub after the ones added before.
    ///
    /// - Parameter stub: The stub to add.
    /// - Returns: A copy of the builder with the stub added.
    @discardableResult
    public func addStub(_ stub: HTTPStub) -> Self {
        var copy = self
        copy.stubs.append(stub)
        return copy
    }

    /// Runs `onShutdown` when the built client is shut down, for example to check that the
    /// code under test shuts it down.
    ///
    /// - Parameter onShutdown: Runs on shutdown. An error it throws is thrown by
    ///   `NetSkeinClient.shutdown()`.
    /// - Returns: A copy of the builder with this closure, replacing any set before.
    @discardableResult
    public func onShutdown(_ onShutdown: @escaping @Sendable () async throws -> Void) -> Self {
        var copy = self
        copy.onShutdown = onShutdown
        return copy
    }
}

extension TestClientBuilder {
    /// Creates a client that answers requests from the stubs added so far.
    ///
    /// Each call creates a client with its own ``MockHTTPClient``, so call counts and
    /// recorded requests are not shared between clients.
    ///
    /// - Returns: The client.
    public func build() -> NetSkeinClient {
        let transport = MockHTTPClient(stubs: stubs, onShutdown: onShutdown)
        return NetSkeinClient(
            transport: transport,
            defaultHeaders: defaultHeaders,
            cookieJar: cookieJar,
            cache: cache,
            circuitBreaker: circuitBreaker,
            retryPolicy: retryPolicy,
            callTimeout: callTimeout,
            attemptMiddlewares: attemptMiddlewares,
            callMiddlewares: callMiddlewares,
            tracer: tracer,
            logger: logger
        )
    }
}

extension NetSkeinClient {
    /// Starts building a client whose requests are answered by ``HTTPStub``s instead of the
    /// network.
    ///
    /// ```swift
    /// let client = NetSkeinClient.testing()
    ///     .addStub(HTTPStub.get("https://api.example.com/me").text("Ada"))
    ///     .build()
    /// ```
    ///
    /// - Returns: A builder with no stubs and the default settings.
    public static func testing() -> TestClientBuilder {
        TestClientBuilder()
    }
}

extension LoggerLabel {
    static let test: String = "com.netskein.test"
}
