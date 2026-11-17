import NIOCore
import NetSkein

extension HTTPCache {
    /// A cache whose idea of the current time comes from `clock`, so tests can make responses
    /// stale by advancing it instead of waiting.
    ///
    /// The other parameters mean the same as in
    /// `HTTPCache.init(storage:maxEntryBytes:defaultTTL:maxStaleOnError:defaultPolicy:)`, and have
    /// the same defaults.
    ///
    /// - Parameters:
    ///   - clock: Where the cache reads the current time.
    ///   - storage: Where responses are kept (default: a `MemoryCacheStorage` of 10 MiB).
    ///   - maxEntryBytes: Responses with a larger body are not stored (default: 1 MiB).
    ///   - defaultTTL: How long a response stays fresh when the server sends neither `max-age`
    ///     nor `Expires` (default: `nil`).
    ///   - maxStaleOnError: How long past its expiry a cached response may stand in for a
    ///     failure (default: `nil`).
    ///   - defaultPolicy: The policy for requests that do not set their own
    ///     (default: `CachePolicy.default`).
    /// - Returns: The cache.
    public static func testing(
        clock: TestClock,
        storage: some CacheStorage = MemoryCacheStorage(maxBytes: 10 * 1024 * 1024),
        maxEntryBytes: Int = 1024 * 1024,
        defaultTTL: TimeAmount? = nil,
        maxStaleOnError: TimeAmount? = nil,
        defaultPolicy: CachePolicy = .default
    ) -> HTTPCache {
        HTTPCache(
            storage: storage,
            maxEntryBytes: maxEntryBytes,
            defaultTTL: defaultTTL,
            maxStaleOnError: maxStaleOnError,
            defaultPolicy: defaultPolicy,
            now: { clock.now }
        )
    }
}
