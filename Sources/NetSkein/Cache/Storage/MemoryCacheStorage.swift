import NIOConcurrencyHelpers
import NIOCore

/// Keeps cached responses in memory, evicting the least recently used URLs once their bodies
/// take more than `maxBytes`.
///
/// - Note: The contents are lost when the app quits. Use ``DiskCacheStorage`` to keep them
///   between launches.
public final class MemoryCacheStorage {
    /// The entries of one URL.
    private struct Slot {
        var entries: [CachedResponse]
        /// The size of the entries' bodies, which is all that counts towards `maxBytes`.
        var bytes: Int
        /// The `clock` value when the URL was last read or stored. The lowest is evicted first.
        var lastUsed: UInt64
    }

    private struct State {
        var slots: [String: Slot] = [:]
        /// The sum of every slot's `bytes`.
        var totalBytes = 0
        /// Counts reads and stores, to order slots by use without reading the system clock.
        var clock: UInt64 = 0

        /// Advances `clock` and returns its new value.
        mutating func tick() -> UInt64 {
            clock += 1
            return clock
        }
    }

    private let maxBytes: Int
    private let stateBox: NIOLockedValueBox<State>

    /// Creates an empty storage.
    ///
    /// - Parameter maxBytes: The most body bytes kept across all URLs. Headers are not counted.
    ///   A URL whose entries are larger on their own is not stored. Values below 0 count as 0.
    public init(maxBytes: Int) {
        self.maxBytes = max(0, maxBytes)
        self.stateBox = NIOLockedValueBox(State())
    }
}

extension MemoryCacheStorage: CacheStorage {
    /// Every entry stored for `url`, marking the URL as recently used.
    ///
    /// - Parameter url: The cache's key for the URL.
    /// - Returns: The entries, or an empty array.
    public func entries(for url: String) async -> [CachedResponse] {
        stateBox.withLockedValue { state in
            guard var slot = state.slots[url] else { return [] }
            slot.lastUsed = state.tick()
            state.slots[url] = slot
            return slot.entries
        }
    }

    /// Replaces every entry stored for `url` with `entries`, then evicts the least recently
    /// used URLs until the total fits in `maxBytes`.
    ///
    /// The entries of a URL are kept or evicted together. When they are larger than `maxBytes`
    /// on their own, the URL is removed instead.
    ///
    /// - Parameters:
    ///   - entries: The entries to keep. An empty array removes the URL.
    ///   - url: The cache's key for the URL.
    public func store(_ entries: [CachedResponse], for url: String) async {
        let bytes = entries.reduce(0) { $0 + $1.body.readableBytes }

        stateBox.withLockedValue { state in
            if let old = state.slots.removeValue(forKey: url) {
                state.totalBytes -= old.bytes
            }

            guard !entries.isEmpty, bytes <= maxBytes else { return }

            state.slots[url] = Slot(entries: entries, bytes: bytes, lastUsed: state.tick())
            state.totalBytes += bytes

            while state.totalBytes > maxBytes,
                let oldest = state.slots.min(by: { $0.value.lastUsed < $1.value.lastUsed })
            {
                state.slots[oldest.key] = nil
                state.totalBytes -= oldest.value.bytes
            }
        }
    }

    /// Removes every entry stored for `url`.
    ///
    /// - Parameter url: The cache's key for the URL.
    public func remove(url: String) async {
        stateBox.withLockedValue { state in
            if let old = state.slots.removeValue(forKey: url) {
                state.totalBytes -= old.bytes
            }
        }
    }

    /// Removes every entry.
    public func removeAll() async {
        stateBox.withLockedValue { state in
            state.slots.removeAll()
            state.totalBytes = 0
        }
    }
}
