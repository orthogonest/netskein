import NIOCore
import NetSkein

extension HTTPCache {
    /// A cache whose idea of the current time comes from `clock`, so tests can make responses
    /// stale by advancing it instead of waiting.
    ///
    /// The other parameters mean the same as in
    /// `HTTPCache.init(storage:maxEntryBytes:defaultTTL:maxStaleOnError:defaultPolicy:)`, and have
    /// the same defaults.
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
