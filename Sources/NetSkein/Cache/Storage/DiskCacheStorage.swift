import NIOCore
import NIOPosix

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(Bionic)
    import Bionic
#endif

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Keeps cached responses in files, so they survive restarts, evicting the least recently used
/// URLs once the files take more than `maxBytes`.
///
/// Each URL is one file in `directory`, named after a hash of the URL and holding all of its
/// `Vary` variants. Files are written in the `.partial` subdirectory and then renamed into
/// place, so a crash never leaves a partial entry; leftovers are cleared on the next start. A
/// file that cannot be read, was written by another format version, or belongs to another URL
/// is treated as missing; unreadable ones are deleted. File access runs on NIO's thread pool,
/// off Swift's cooperative threads, and finishes even when the request that started it is
/// cancelled.
///
/// Storing never fails loudly: a response that cannot be written is simply not cached.
///
/// Only files ending in `.cache` and the `.partial` subdirectory are read or removed, so the
/// directory may hold other files. One directory must not be shared by several processes, such
/// as an app and its extensions: each would keep its own view of the files. Implement
/// ``CacheStorage`` on a database such as SQLite when processes need to share a cache.
public actor DiskCacheStorage: CacheStorage {
    private struct IndexEntry {
        var bytes: Int
        var lastUsed: UInt64
    }

    private struct RenameFailed: Error {}

    private let directory: String
    private let maxBytes: Int
    private let threadPool: NIOThreadPool

    /// The cache files on disk, complete once `loading` has finished.
    private var files: [String: IndexEntry]
    private var totalBytes: Int
    private var clock: UInt64
    /// Reads the directory on first use, rather than in `init`; every caller waits for the same
    /// load.
    private var loading: Task<Void, Never>?

    /// - Parameters:
    ///   - directory: Where the files are kept; created if missing. Use a caches directory, so
    ///     the system may reclaim the space when the device runs low.
    ///   - maxBytes: The most the files may take together before the least recently used are
    ///     removed. It counts file sizes; the disk may use somewhat more, since files occupy
    ///     whole blocks.
    /// - Throws: When `directory` cannot be created.
    public init(directory: String, maxBytes: Int) throws {
        try self.init(directory: directory, maxBytes: maxBytes, threadPool: .singleton)
    }

    init(directory: String, maxBytes: Int, threadPool: NIOThreadPool) throws {
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        self.directory = directory
        self.maxBytes = max(0, maxBytes)
        self.threadPool = threadPool
        self.files = [:]
        self.totalBytes = 0
        self.clock = 0
        self.loading = nil
    }
}

extension DiskCacheStorage {
    public func entries(for url: String) async -> [CachedResponse] {
        await ensureLoaded()
        let name = Self.fileName(for: url)

        // Most lookups are misses; the index answers them without touching the disk
        guard let stored = files[name] else { return [] }

        // Larger than anything this storage writes, so not one of its files; never read it
        guard stored.bytes <= maxBytes else {
            await discard(name)
            return []
        }

        let path = self.path(of: name)
        let decoded = await perform { () throws -> (url: String, entries: [CachedResponse])? in
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return CacheFileCodec.decode(ByteBuffer(bytes: data))
        }

        // `perform` adds its own optional for a failed read; either way the file is unusable
        guard case let .some(.some(decoded)) = decoded else {
            // Unreadable, truncated or from another format version: it will never be usable
            await discard(name)
            return []
        }

        // Another URL with the same hash owns this file; leave it for that URL
        guard decoded.url == url else { return [] }

        files[name]?.lastUsed = tick()
        return decoded.entries
    }

    public func store(_ entries: [CachedResponse], for url: String) async {
        await ensureLoaded()
        let name = Self.fileName(for: url)

        guard !entries.isEmpty else {
            await discard(name)
            return
        }

        let bytes = CacheFileCodec.encode(entries, url: url)
        guard bytes.readableBytes <= maxBytes else {
            await discard(name)
            return
        }

        let path = self.path(of: name)
        // A name of its own, so concurrent stores for the same URL never share a partial file
        let partialPath = partialDirectory + "/" + name + ".\(tick())"
        let written: Void? = await perform {
            try Data(bytes.readableBytesView).write(to: URL(fileURLWithPath: partialPath))
            // rename(2) replaces the old file in one step, so readers see the old or the new one
            guard rename(partialPath, path) == 0 else {
                try? FileManager.default.removeItem(atPath: partialPath)
                throw RenameFailed()
            }
        }
        guard written != nil else { return }

        // Two stores for the same URL can finish in either order, so until the next start the
        // size recorded here may be the other write's
        totalBytes -= files[name]?.bytes ?? 0
        files[name] = IndexEntry(bytes: bytes.readableBytes, lastUsed: tick())
        totalBytes += bytes.readableBytes

        var evicted: [String] = []
        while totalBytes > maxBytes,
            let oldest = files.min(by: { $0.value.lastUsed < $1.value.lastUsed })
        {
            files[oldest.key] = nil
            totalBytes -= oldest.value.bytes
            evicted.append(oldest.key)
        }

        // The index already forgot them, so a lookup meanwhile is a plain miss
        let paths = evicted.map(self.path(of:))
        await perform {
            for path in paths { try? FileManager.default.removeItem(atPath: path) }
        }
    }

    public func remove(url: String) async {
        await ensureLoaded()
        await discard(Self.fileName(for: url))
    }

    public func removeAll() async {
        await ensureLoaded()
        files = [:]
        totalBytes = 0

        let directory = self.directory
        await perform {
            for name in try Self.cacheFiles(in: directory) {
                try? FileManager.default.removeItem(atPath: directory + "/" + name)
            }
        }
    }
}

// MARK: - Index

extension DiskCacheStorage {
    private func ensureLoaded() async {
        if loading == nil {
            loading = Task { await load() }
        }
        await loading?.value
    }

    /// Clears partial files left by a crash, then indexes the cache files, oldest modified first.
    private func load() async {
        let directory = self.directory
        let partialDirectory = self.partialDirectory

        let stored = await perform { () throws -> [StoredFile] in
            try? FileManager.default.removeItem(atPath: partialDirectory)
            try FileManager.default.createDirectory(
                atPath: partialDirectory,
                withIntermediateDirectories: true
            )

            return try Self.cacheFiles(in: directory)
                .compactMap { name in
                    let attributes = try? FileManager.default.attributesOfItem(
                        atPath: directory + "/" + name
                    )
                    return attributes.flatMap { StoredFile(name: name, attributes: $0) }
                }
        }

        for file in (stored ?? []).sorted(by: { $0.modified < $1.modified }) {
            files[file.name] = IndexEntry(bytes: file.bytes, lastUsed: tick())
            totalBytes += file.bytes
        }
    }

    private func discard(_ name: String) async {
        guard let removed = files.removeValue(forKey: name) else { return }
        totalBytes -= removed.bytes

        let path = self.path(of: name)
        await perform { try FileManager.default.removeItem(atPath: path) }
    }

    private func tick() -> UInt64 {
        // A UInt64 cannot overflow in practice: even a billion cache operations per second
        // would take centuries to reach UInt64.max
        clock += 1
        return clock
    }
}

// MARK: - Files

extension DiskCacheStorage {
    /// A cache file found on disk when the index is built.
    struct StoredFile: Sendable {
        let name: String
        let bytes: Int
        let modified: Date

        /// `nil` when the attributes lack a size or modification date; such a file is ignored.
        init?(name: String, attributes: [FileAttributeKey: Any]) {
            guard
                let bytes = attributes[.size] as? Int,
                let modified = attributes[.modificationDate] as? Date
            else { return nil }
            self.name = name
            self.bytes = bytes
            self.modified = modified
        }
    }

    /// The file name for `url`: its 64-bit FNV-1a hash in hex. Collisions are possible, so each
    /// file also records its URL.
    static func fileName(for url: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16) + ".cache"
    }

    private static func cacheFiles(in directory: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".cache") }
    }

    private var partialDirectory: String {
        directory + "/.partial"
    }

    private func path(of name: String) -> String {
        directory + "/" + name
    }

    /// Runs blocking file work on the thread pool; `nil` when it throws.
    @discardableResult
    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async -> T? {
        let threadPool = self.threadPool
        // An unstructured task is not cancelled with its caller, so cancelling a request can
        // neither make a good file look unreadable nor leave a write half recorded
        return try? await Task { try await threadPool.runIfActive(work) }.value
    }
}
