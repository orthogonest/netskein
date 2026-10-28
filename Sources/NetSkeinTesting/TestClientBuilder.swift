import AsyncHTTPClient
import Logging
import NIOHTTP1
import NetSkein
import Tracing

public struct TestClientBuilder: Sendable {
    private var defaultHeaders: HTTPHeaders
    private var cookieJar: CookieJar?
    private var retryPolicy: RetryPolicy
    private var middlewares: [any HTTPMiddleware]
    private var tracer: (any Tracer)?
    private var logger: Logger
    private var stubs: [HTTPStub]
    private var onShutdown: (@Sendable () async throws -> Void)?

    public init() {
        self.stubs = []
        defaultHeaders = HTTPHeaders()
        retryPolicy = .standard()
        middlewares = []
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

    @discardableResult
    public func retryPolicy(_ policy: RetryPolicy) -> Self {
        var copy = self
        copy.retryPolicy = policy
        return copy
    }

    @discardableResult
    public func using(_ middleware: some HTTPMiddleware) -> Self {
        var copy = self
        copy.middlewares.append(middleware)
        return copy
    }

    @discardableResult
    public func using(
        _ intercept:
            @escaping @Sendable (RequestHead, MiddlewareContext, HTTPMiddleware.Next)
            async throws -> HTTPClientResponse
    ) -> Self {
        using(ClosureMiddleware(intercept))
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
            retryPolicy: retryPolicy,
            middlewares: middlewares,
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
