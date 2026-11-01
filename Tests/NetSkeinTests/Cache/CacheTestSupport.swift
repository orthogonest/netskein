import AsyncHTTPClient
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1

@testable import NetSkein
@testable import NetSkeinTesting

/// Answers each request with the next scripted reply and records what was sent.
final class ScriptedTransport: HTTPTransport {
    enum Reply: Sendable {
        case response(
            HTTPResponseStatus,
            HTTPHeaders = [:],
            body: String = "",
            redirected: Bool = false
        )
        case failure
    }

    struct UnexpectedRequest: Error {}
    struct ConnectionDropped: Error {}

    private let replies: NIOLockedValueBox<[Reply]>
    private let sent = NIOLockedValueBox<[HTTPClientRequest]>([])

    init(_ replies: [Reply]) {
        self.replies = NIOLockedValueBox(replies)
    }

    var requests: [HTTPClientRequest] { sent.withLockedValue { $0 } }

    func execute(
        _ request: HTTPClientRequest,
        timeout: TimeAmount,
        logger: Logger?
    ) async throws -> HTTPClientResponse {
        sent.withLockedValue { $0.append(request) }
        let reply = replies.withLockedValue { $0.isEmpty ? nil : $0.removeFirst() }

        switch reply {
        case let .response(status, headers, body, redirected):
            let history =
                redirected
                ? [
                    HTTPClientRequestResponse(
                        request: request,
                        responseHead: HTTPResponseHead(version: .http1_1, status: .found)
                    ),
                    HTTPClientRequestResponse(
                        request: request,
                        responseHead: HTTPResponseHead(version: .http1_1, status: status)
                    ),
                ]
                : []
            return HTTPClientResponse(
                status: status,
                headers: headers,
                body: .bytes(ByteBuffer(string: body)),
                history: history
            )
        case .failure:
            throw ConnectionDropped()
        case nil:
            throw UnexpectedRequest()
        }
    }

    func shutdown() async throws {}
}

func makeCache(
    clock: TestClock,
    storage: some CacheStorage = MemoryCacheStorage(maxBytes: 1024 * 1024),
    maxEntryBytes: Int = 1024,
    defaultTTL: TimeAmount? = nil,
    maxStaleOnError: TimeAmount? = nil,
    defaultPolicy: CachePolicy = .default
) -> HTTPCache {
    // A small maxEntryBytes by default, so tests can exceed it with short bodies
    HTTPCache.testing(
        clock: clock,
        storage: storage,
        maxEntryBytes: maxEntryBytes,
        defaultTTL: defaultTTL,
        maxStaleOnError: maxStaleOnError,
        defaultPolicy: defaultPolicy
    )
}

func makeClient(
    _ transport: ScriptedTransport,
    cache: HTTPCache,
    transportDecompresses: Bool = false,
    middlewares: [any HTTPMiddleware] = []
) -> NetSkeinClient {
    NetSkeinClient(
        transport: transport,
        defaultHeaders: [:],
        cookieJar: nil,
        cache: cache,
        transportDecompresses: transportDecompresses,
        retryPolicy: .disabled,
        middlewares: middlewares,
        tracer: nil,
        logger: Logger(label: LoggerLabel.test)
    )
}

let itemsURL = "https://api.example.com/items"

extension NetSkeinResponse {
    /// This cache's `Cache-Status` member, such as `hit`.
    var cacheStatus: String? { headers.netSkeinCacheStatus }
}
