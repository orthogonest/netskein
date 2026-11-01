import NIOCore

/// How one request uses the client's ``HTTPCache``.
///
/// Set per request with ``NetSkeinRequest/cachePolicy(_:)``, or for every request with
/// ``HTTPCache/defaultPolicy``. Request `Cache-Control` directives sent with
/// ``NetSkeinRequest/header(_:_:)`` are honoured as well.
public enum CachePolicy: Sendable, Equatable {
    /// Follow the server's caching headers and RFC 9111.
    case `default`

    /// Always ask the server. A cached response is only reused when the server confirms it is
    /// unchanged with `304 Not Modified`.
    ///
    /// Sends `Cache-Control: no-cache`, so caches between the client and the server, such as a
    /// CDN, revalidate too.
    case reloadIgnoringCache

    /// Use cached responses as usual, but never store this request's response.
    ///
    /// Sends `Cache-Control: no-store`, so caches between the client and the server do not
    /// store it either. Use it for responses that must not be kept on the device.
    case noStore

    /// Use a cached response however old it is, and only go to the network when there is
    /// none. Includes responses stored with ``fresh(for:)``.
    case returnCacheElseLoad

    /// Never go to the network: use a cached response however old it is, or return
    /// `504 Gateway Timeout` when there is none. Includes responses stored with ``fresh(for:)``.
    case onlyIfCached

    /// Treat the response as fresh for `ttl`, ignoring the server's caching headers, including
    /// `no-store`.
    ///
    /// This goes against what the server asked, so use it only for responses you know are safe
    /// to reuse, such as reference data from a backend that forbids caching everything.
    /// Responses stored this way are only used by requests with this policy,
    /// ``returnCacheElseLoad`` or ``onlyIfCached``; ``default`` requests never see them.
    case fresh(for: TimeAmount)
}

extension CachePolicy {
    /// The `Cache-Control` directive this policy adds to the request, for the server and any
    /// cache on the way.
    var requestDirective: String? {
        switch self {
        case .reloadIgnoringCache: "no-cache"
        case .noStore: "no-store"
        case .default, .returnCacheElseLoad, .onlyIfCached, .fresh: nil
        }
    }
}
