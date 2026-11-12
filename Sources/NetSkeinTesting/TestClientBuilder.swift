import AsyncHTTPClient
import Logging
import NIOCore
import NIOHTTP1
import NetSkein
import Tracing

/// Builds a `NetSkeinClient` whose requests are answered by ``HTTPStub``s through a
/// ``MockHTTPClient`` instead of the network.
///
/// Start one with ``NetSkein/NetSkeinClient/testing()``. It offers the same options as the
/// production builder that matter in tests: default headers, cookies, cache, retry policy,
/// middleware, tracer and logger.
///
/// Its defaults match the production builder, so code behaves the same in tests as in the app:
/// in particular, requests are not retried unless a test sets ``retryPolicy(_:)``.
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
    @discardableResult
    public func defaultHeaders(_ headers: HTTPHeaders) -> Self {
        var copy = self
        copy.defaultHeaders = headers
        return copy
    }

    @discardableResult
    public func cookieJar(_ jar: CookieJar) -> Self {
        var copy = self
        copy.cookieJar = jar
        return copy
    }

    /// Caches responses as described by `HTTPCache`.
    @discardableResult
    public func cache(_ cache: HTTPCache) -> Self {
        var copy = self
        copy.cache = cache
        return copy
    }

    /// Rejects requests to servers that keep failing, as described by `CircuitBreaker`.
    @discardableResult
    public func circuitBreaker(_ breaker: CircuitBreaker) -> Self {
        var copy = self
        copy.circuitBreaker = breaker
        return copy
    }

    @discardableResult
    public func retryPolicy(_ policy: RetryPolicy) -> Self {
        var copy = self
        copy.retryPolicy = policy
        return copy
    }

    /// Limits every call made by the built client, attempts and waits included. Requests can
    /// change it with `NetSkeinRequest.callTimeout(_:)`. Calls have no overall limit unless this is set.
    @discardableResult
    public func callTimeout(_ duration: TimeAmount) -> Self {
        var copy = self
        copy.callTimeout = duration
        return copy
    }

    /// Adds a middleware that runs once per call, or for every attempt (the default), as
    /// `scope` says.
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
    @discardableResult
    public func tracer(_ tracer: any Tracer) -> Self {
        var copy = self
        copy.tracer = tracer
        return copy
    }

    @discardableResult
    public func disableTracing() -> Self {
        var copy = self
        copy.tracer = nil
        return copy
    }

    @discardableResult
    public func logger(_ logger: Logger) -> Self {
        var copy = self
        copy.logger = logger
        return copy
    }

    @discardableResult
    public func addStubs(_ stubs: [HTTPStub]) -> Self {
        var copy = self
        copy.stubs.append(contentsOf: stubs)
        return copy
    }

    @discardableResult
    public func addStub(_ stub: HTTPStub) -> Self {
        var copy = self
        copy.stubs.append(stub)
        return copy
    }

    @discardableResult
    public func onShutdown(_ onShutdown: @escaping @Sendable () async throws -> Void) -> Self {
        var copy = self
        copy.onShutdown = onShutdown
        return copy
    }
}

extension TestClientBuilder {
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
    public static func testing() -> TestClientBuilder {
        TestClientBuilder()
    }
}

extension LoggerLabel {
    static let test: String = "com.netskein.test"
}
