/// Where an ``HTTPCache`` keeps its responses.
///
/// A storage only keeps and evicts entries; ``HTTPCache`` applies every RFC 9111 rule, so a
/// custom storage needs no HTTP knowledge. Entries are grouped by URL: one URL can have
/// several entries when the server's `Vary` header makes responses depend on request headers.
public protocol CacheStorage: Sendable {
    /// Every entry stored for `url`, or an empty array.
    func entries(for url: String) async -> [CachedResponse]

    /// Replaces every entry stored for `url` with `entries`.
    func store(_ entries: [CachedResponse], for url: String) async

    /// Removes every entry stored for `url`.
    func remove(url: String) async

    /// Removes every entry.
    func removeAll() async
}
