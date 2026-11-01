import NIOConcurrencyHelpers

/// Keeps cached responses in memory, evicting the least recently used URLs once their bodies
/// take more than `maxBytes`.
public final class MemoryCacheStorage {
    private struct Slot {
        var entries: [CachedResponse]
        var bytes: Int
        var lastUsed: UInt64
    }

    private struct State {
        var slots: [String: Slot] = [:]
        var totalBytes = 0
        var clock: UInt64 = 0

        mutating func tick() -> UInt64 {
            clock += 1
            return clock
        }
    }

    private let maxBytes: Int
    private let stateBox: NIOLockedValueBox<State>

    public init(maxBytes: Int) {
        self.maxBytes = max(0, maxBytes)
        self.stateBox = NIOLockedValueBox(State())
    }
}

extension MemoryCacheStorage: CacheStorage {
    public func entries(for url: String) async -> [CachedResponse] {
        stateBox.withLockedValue { state in
            guard var slot = state.slots[url] else { return [] }
            slot.lastUsed = state.tick()
            state.slots[url] = slot
            return slot.entries
        }
    }

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

    public func remove(url: String) async {
        stateBox.withLockedValue { state in
            if let old = state.slots.removeValue(forKey: url) {
                state.totalBytes -= old.bytes
            }
        }
    }

    public func removeAll() async {
        stateBox.withLockedValue { state in
            state.slots.removeAll()
            state.totalBytes = 0
        }
    }
}
