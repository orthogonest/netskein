/// Where an ``HTTPCache`` keeps its responses.
///
/// A storage only keeps and evicts entries. ``HTTPCache`` applies every RFC 9111 rule, so a
/// custom storage needs no HTTP knowledge. Entries are grouped by URL: one URL can have
/// several entries when the server's `Vary` header makes responses depend on request headers.
public protocol CacheStorage: Sendable {
    /// Every entry stored for `url`, or an empty array.
    ///
    /// - Parameter url: The cache's key for the URL.
    /// - Returns: The entries, as last passed to ``store(_:for:)``.
    func entries(for url: String) async -> [CachedResponse]

    /// Replaces every entry stored for `url` with `entries`.
    ///
    /// The storage may keep fewer entries, or none, to stay within its limits.
    ///
    /// - Parameters:
    ///   - entries: The entries to keep. An empty array removes the URL.
    ///   - url: The cache's key for the URL.
    func store(_ entries: [CachedResponse], for url: String) async

    /// Removes every entry stored for `url`.
    ///
    /// - Parameter url: The cache's key for the URL.
    func remove(url: String) async

    /// Removes every entry.
    func removeAll() async
}
