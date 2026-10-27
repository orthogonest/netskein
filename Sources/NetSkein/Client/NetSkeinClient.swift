import AsyncHTTPClient
import Logging
import NIOHTTP1

public final class NetSkeinClient<Transport: HTTPTransport>: Sendable {
    let transport: Transport
    let defaultHeaders: HTTPHeaders
    let cookieJar: CookieJar?
    let retryPolicy: RetryPolicy
    let middlewares: [any HTTPMiddleware]
    let logger: Logger
    let percentEncoder: PercentEncoder

    public init(
        transport: Transport,
        defaultHeaders: HTTPHeaders = .init(),
        cookieJar: CookieJar? = nil,
        retryPolicy: RetryPolicy = .disabled,
        middlewares: [any HTTPMiddleware] = [],
        logger: Logger,
        percentEncoder: PercentEncoder = .default,
    ) {
        self.transport = transport
        self.defaultHeaders = defaultHeaders
        self.cookieJar = cookieJar
        self.retryPolicy = retryPolicy
        self.middlewares = middlewares
        self.logger = logger
        self.percentEncoder = percentEncoder
    }
}

extension NetSkeinClient where Transport == HTTPClient {
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
    public func get(_ url: String) -> NetSkeinRequest<Transport, BodyForbidden> {
        NetSkeinRequest(client: self, method: .GET, url: url, percentEncoder: percentEncoder)
    }

    public func post(_ url: String) -> NetSkeinRequest<Transport, BodyAllowed> {
        NetSkeinRequest(client: self, method: .POST, url: url, percentEncoder: percentEncoder)
    }

    public func put(_ url: String) -> NetSkeinRequest<Transport, BodyAllowed> {
        NetSkeinRequest(client: self, method: .PUT, url: url, percentEncoder: percentEncoder)
    }

    public func patch(_ url: String) -> NetSkeinRequest<Transport, BodyAllowed> {
        NetSkeinRequest(client: self, method: .PATCH, url: url, percentEncoder: percentEncoder)
    }

    public func delete(_ url: String) -> NetSkeinRequest<Transport, BodyForbidden> {
        NetSkeinRequest(client: self, method: .DELETE, url: url, percentEncoder: percentEncoder)
    }

    public func request(
        _ method: HTTPMethod,
        url: String
    ) -> NetSkeinRequest<Transport, BodyAllowed> {
        NetSkeinRequest<Transport, BodyAllowed>(
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
