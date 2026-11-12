import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1

/// A private HTTP cache that follows RFC 9111.
///
/// Create one, keep a reference, and pass it to the client builder's `cache(_:)`. The cache
/// is safe to share between clients.
///
/// ```swift
/// let cache = HTTPCache(storage: MemoryCacheStorage(maxBytes: 20 * 1024 * 1024))
/// let client = NetSkeinClient.builder().cache(cache).build()
///
/// // On logout
/// await cache.removeAll()
/// ```
///
/// ## What is cached
///
/// Only responses to ``NetSkeinRequest/send()`` for `GET` requests without a body are stored
/// and reused. `stream(_:)` and `download(toFileAtPath:resumption:onProgress:)` always go to
/// the network. A successful `POST`, `PUT`, `PATCH` or `DELETE` removes the cached responses
/// for its URL. Requests that carry their own conditional or `Range` headers bypass the cache.
///
/// Every response gets a `Cache-Status` header (RFC 9211) saying whether it was a `hit`, or
/// why the request went to the network (`fwd=uri-miss`, `fwd=vary-miss`, `fwd=stale`,
/// `fwd=request`).
///
/// ## RFC 9111 conformance
///
/// The cache follows every requirement for a private cache: freshness from `max-age` and
/// `Expires` with the full age calculation, `Vary`, revalidation with `ETag` and
/// `Last-Modified`, invalidation by unsafe methods, and the response directives `no-store`,
/// `no-cache`, `must-revalidate`, `must-understand`, `private` and `public`, and the request
/// directives `no-store`, `no-cache`, `max-age`, `max-stale`, `min-fresh` and
/// `only-if-cached`, plus `Pragma: no-cache`.
///
/// It does not store partial (`206`) responses, never stores `Set-Cookie`, and does not
/// store responses that arrived through a redirect. Without `defaultTTL`, a response without
/// `max-age` or `Expires` is stored but treated as stale, so it is revalidated before reuse.
public final class HTTPCache: Sendable {
    let storage: any CacheStorage
    let maxEntryBytes: Int
    let defaultTTL: TimeAmount?
    let maxStaleOnError: TimeAmount?
    let now: @Sendable () -> Date
    private let policy: NIOLockedValueBox<CachePolicy>

    /// - Parameters:
    ///   - storage: Where responses are kept.
    ///   - maxEntryBytes: Responses with a larger body are not stored.
    ///   - defaultTTL: How long a response stays fresh when the server sends neither
    ///     `max-age` nor `Expires`. This is RFC 9111's heuristic freshness: it never overrides
    ///     the server's headers and only applies to status codes that are cacheable by
    ///     default, such as `200` and `404`, or to responses marked `public`.
    ///   - maxStaleOnError: How long past its expiry a cached response may still stand in when the
    ///     server cannot be reached or answers `500`, `502`, `503` or `504`: the client-side
    ///     version of RFC 5861's `stale-if-error`. `nil`, the default, returns the failure instead. Responses marked `must-revalidate` or
    ///     `no-cache` are never used this way. Such responses carry
    ///     `Cache-Status: NetSkein; fwd=stale; detail=error`, and are returned without retrying.
    ///     A server's own `stale-if-error` directive is ignored, so serving stale data on error
    ///     stays the app's choice.
    ///   - defaultPolicy: The policy for requests that do not set their own. See
    ///     ``defaultPolicy``.
    public convenience init(
        storage: some CacheStorage = MemoryCacheStorage(maxBytes: 10 * 1024 * 1024),
        maxEntryBytes: Int = 1024 * 1024,
        defaultTTL: TimeAmount? = nil,
        maxStaleOnError: TimeAmount? = nil,
        defaultPolicy: CachePolicy = .default
    ) {
        self.init(
            storage: storage,
            maxEntryBytes: maxEntryBytes,
            defaultTTL: defaultTTL,
            maxStaleOnError: maxStaleOnError,
            defaultPolicy: defaultPolicy,
            now: { Date() }
        )
    }

    /// The full initializer, with the clock injected. `NetSkeinTesting` uses it for
    /// `HTTPCache.testing(…)`.
    package init(
        storage: any CacheStorage,
        maxEntryBytes: Int,
        defaultTTL: TimeAmount?,
        maxStaleOnError: TimeAmount?,
        defaultPolicy: CachePolicy,
        now: @escaping @Sendable () -> Date
    ) {
        self.storage = storage
        self.maxEntryBytes = max(0, maxEntryBytes)
        self.defaultTTL = defaultTTL
        self.maxStaleOnError = maxStaleOnError
        self.now = now
        self.policy = NIOLockedValueBox(defaultPolicy)
    }
}

extension HTTPCache {
    /// The policy for requests that do not set one with ``NetSkeinRequest/cachePolicy(_:)``.
    ///
    /// It can be changed at any time, for example to ``CachePolicy/returnCacheElseLoad`` while
    /// the app is offline. Requests already sent keep the policy they started with.
    public var defaultPolicy: CachePolicy {
        get { policy.withLockedValue { $0 } }
        set { policy.withLockedValue { $0 = newValue } }
    }

    /// Removes every cached response for `url`.
    public func remove(url: String) async {
        guard let key = Self.key(for: url) else { return }
        await storage.remove(url: key)
    }

    /// Removes every cached response, for example on logout.
    public func removeAll() async {
        await storage.removeAll()
    }
}

extension HTTPCache {
    /// The storage key for `url`: without its fragment, with the scheme and host lowercased and
    /// a default port removed, so equivalent URLs share entries. `nil` for a URL without a host.
    static func key(for url: String) -> String? {
        guard
            var components = URLComponents(string: url),
            let host = components.host
        else {
            return nil
        }

        let scheme = components.scheme?.lowercased()
        components.scheme = scheme
        components.host = host.lowercased()
        components.fragment = nil

        if (scheme == "http" && components.port == 80)
            || (scheme == "https" && components.port == 443)
        {
            components.port = nil
        }

        return components.string
    }
}

extension HTTPHeaders {
    /// This cache's `Cache-Status` member without the cache name, such as `hit` or
    /// `fwd=uri-miss; stored`.
    var netSkeinCacheStatus: String? {
        self["Cache-Status"].flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("NetSkein;") }
            .map { $0.dropFirst("NetSkein;".count).trimmingCharacters(in: .whitespaces) }
    }
}
