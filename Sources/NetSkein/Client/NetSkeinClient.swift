import AsyncHTTPClient
import Logging
import NIOHTTP1
import Tracing

public final class NetSkeinClient: Sendable {
    let transport: any HTTPTransport
    let defaultHeaders: HTTPHeaders
    let cookieJar: CookieJar?
    let retryPolicy: RetryPolicy
    let middlewares: [any HTTPMiddleware]
    let tracer: (any Tracer)?
    let logger: Logger
    let percentEncoder: PercentEncoder

    public init(
        transport: some HTTPTransport,
        defaultHeaders: HTTPHeaders = .init(),
        cookieJar: CookieJar? = nil,
        retryPolicy: RetryPolicy = .disabled,
        middlewares: [any HTTPMiddleware] = [],
        tracer: (any Tracer)? = InstrumentationSystem.tracer,
        logger: Logger,
        percentEncoder: PercentEncoder = .default,
    ) {
        self.transport = transport
        self.defaultHeaders = defaultHeaders
        self.cookieJar = cookieJar
        self.retryPolicy = retryPolicy
        self.middlewares = middlewares
        self.tracer = tracer
        self.logger = logger
        self.percentEncoder = percentEncoder
    }
}

extension NetSkeinClient {
    public convenience init(
        defaultHeaders: HTTPHeaders = .init(),
        retryPolicy: RetryPolicy = .disabled
    ) {
        let transport = HTTPClient(eventLoopGroupProvider: .singleton, configuration: .init())
        self.init(
            transport: transport,
            defaultHeaders: defaultHeaders,
            retryPolicy: retryPolicy,
            logger: Logger(label: LoggerLabel.identifier)
        )
    }

    public static func builder() -> NetSkeinClientBuilder {
        NetSkeinClientBuilder()
    }
}

extension NetSkeinClient {
    public func get(_ url: String) -> NetSkeinRequest<BodyForbidden> {
        NetSkeinRequest(client: self, method: .GET, url: url, percentEncoder: percentEncoder)
    }

    public func post(_ url: String) -> NetSkeinRequest<BodyAllowed> {
        NetSkeinRequest(client: self, method: .POST, url: url, percentEncoder: percentEncoder)
    }

    public func put(_ url: String) -> NetSkeinRequest<BodyAllowed> {
        NetSkeinRequest(client: self, method: .PUT, url: url, percentEncoder: percentEncoder)
    }

    public func patch(_ url: String) -> NetSkeinRequest<BodyAllowed> {
        NetSkeinRequest(client: self, method: .PATCH, url: url, percentEncoder: percentEncoder)
    }

    public func delete(_ url: String) -> NetSkeinRequest<BodyForbidden> {
        NetSkeinRequest(client: self, method: .DELETE, url: url, percentEncoder: percentEncoder)
    }

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
