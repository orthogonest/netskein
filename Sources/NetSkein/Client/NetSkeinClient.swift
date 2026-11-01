import AsyncHTTPClient
import Foundation
import Logging
import NIOHTTP1
import Tracing

public final class NetSkeinClient: Sendable {
    package let transport: any HTTPTransport
    let defaultHeaders: HTTPHeaders
    let retryPolicy: RetryPolicy
    let middlewares: [any HTTPMiddleware]
    let cache: HTTPCache?
    /// Whether the transport decompresses response bodies but keeps their `Content-Encoding`.
    let transportDecompresses: Bool
    let tracer: (any Tracer)?
    let logger: Logger
    let percentEncoder: PercentEncoder

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

    /// Creates a client that sends requests through `transport`.
    ///
    /// Responses are cached as described by ``HTTPCache`` when `cache` is set. The transport must
    /// not decompress response bodies; build the client with ``NetSkeinClientBuilder`` to combine
    /// caching with automatic decompression.
    public init(
        transport: some HTTPTransport,
        defaultHeaders: HTTPHeaders = .init(),
        cookieJar: CookieJar? = nil,
        cache: HTTPCache? = nil,
        transportDecompresses: Bool = false,
        retryPolicy: RetryPolicy = .disabled,
        middlewares: [any HTTPMiddleware] = [],
        tracer: (any Tracer)? = InstrumentationSystem.tracer,
        logger: Logger,
        percentEncoder: PercentEncoder = .default,
    ) {
        self.transport = transport
        self.defaultHeaders = defaultHeaders
        self.retryPolicy = retryPolicy
        self.middlewares = (cookieJar.map { [CookieMiddleware(jar: $0)] } ?? []) + middlewares
        self.cache = cache
        self.transportDecompresses = transportDecompresses
        self.tracer = tracer
        self.logger = logger
        self.percentEncoder = percentEncoder
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
