import NIOCore
import NIOHTTP1
import Testing

@testable import NetSkein

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The behaviour every ``CacheStorage`` shares, run against each implementation.
struct CacheStorageConformanceTests {
    enum Kind: String, CaseIterable, Sendable {
        case memory
        case disk
    }

    /// A storage of `kind`, and the directory to delete afterwards for disk storage.
    func makeStorage(_ kind: Kind, maxBytes: Int) throws -> (any CacheStorage, String?) {
        switch kind {
        case .memory:
            return (MemoryCacheStorage(maxBytes: maxBytes), nil)
        case .disk:
            let directory = makeTemporaryDirectory()
            return (try DiskCacheStorage(directory: directory, maxBytes: maxBytes), directory)
        }
    }
}

// MARK: - Storing and Reading

extension CacheStorageConformanceTests {
    @Test(
        "CacheStorageConformanceTests: entries are stored, replaced and read back intact",
        arguments: Kind.allCases
    )
    func testStoreReplaceAndRead(kind: Kind) async throws {
        let (storage, directory) = try makeStorage(kind, maxBytes: 10_000)
        defer { removeDirectory(directory) }
        let original = sampleEntry(body: "first", isForced: true)

        await storage.store([original, sampleEntry(body: "second")], for: "https://x/a")
        let stored = await storage.entries(for: "https://x/a")

        #expect(stored.count == 2)
        expectEqual(stored.first, original)

        await storage.store([sampleEntry(body: "third")], for: "https://x/a")
        #expect(await storage.entries(for: "https://x/a").map(\.bodyText) == ["third"])
        #expect(await storage.entries(for: "https://x/missing").isEmpty)
    }

    @Test(
        "CacheStorageConformanceTests: storing nothing, or too much, removes the URL's entries",
        arguments: Kind.allCases
    )
    func testEmptyAndOversized(kind: Kind) async throws {
        let (storage, directory) = try makeStorage(kind, maxBytes: 1_000)
        defer { removeDirectory(directory) }

        await storage.store([sampleEntry(bytes: 100)], for: "https://x/a")
        await storage.store([sampleEntry(bytes: 2_000)], for: "https://x/a")
        #expect(await storage.entries(for: "https://x/a").isEmpty)

        await storage.store([sampleEntry(bytes: 100)], for: "https://x/b")
        await storage.store([], for: "https://x/b")
        #expect(await storage.entries(for: "https://x/b").isEmpty)
    }
}

// MARK: - Eviction and Removal

extension CacheStorageConformanceTests {
    @Test(
        "CacheStorageConformanceTests: the least recently used URL is evicted first",
        arguments: Kind.allCases
    )
    func testEvictsLeastRecentlyUsed(kind: Kind) async throws {
        let (storage, directory) = try makeStorage(kind, maxBytes: 2_500)
        defer { removeDirectory(directory) }

        await storage.store([sampleEntry(bytes: 1_000)], for: "https://x/a")
        await storage.store([sampleEntry(bytes: 1_000)], for: "https://x/b")
        // Reading "a" makes "b" the least recently used
        _ = await storage.entries(for: "https://x/a")
        await storage.store([sampleEntry(bytes: 1_000)], for: "https://x/c")

        #expect(await storage.entries(for: "https://x/a").count == 1)
        #expect(await storage.entries(for: "https://x/b").isEmpty)
        #expect(await storage.entries(for: "https://x/c").count == 1)
    }

    @Test(
        "CacheStorageConformanceTests: remove and removeAll delete entries",
        arguments: Kind.allCases
    )
    func testRemove(kind: Kind) async throws {
        let (storage, directory) = try makeStorage(kind, maxBytes: 10_000)
        defer { removeDirectory(directory) }
        await storage.store([sampleEntry(bytes: 10)], for: "https://x/a")
        await storage.store([sampleEntry(bytes: 10)], for: "https://x/b")

        await storage.remove(url: "https://x/a")
        await storage.remove(url: "https://x/never-stored")
        #expect(await storage.entries(for: "https://x/a").isEmpty)
        #expect(await storage.entries(for: "https://x/b").count == 1)

        await storage.removeAll()
        #expect(await storage.entries(for: "https://x/b").isEmpty)

        await storage.store([sampleEntry(bytes: 10)], for: "https://x/c")
        #expect(await storage.entries(for: "https://x/c").count == 1)
    }
}

// MARK: - Helpers

func sampleEntry(body: String = "", bytes: Int? = nil, isForced: Bool = false) -> CachedResponse {
    CachedResponse(
        status: HTTPResponseStatus(statusCode: 203, reasonPhrase: "Non-Authoritative"),
        headers: ["Cache-Control": "max-age=60", "ETag": "\"v1\"", "X-Multi": "1", "x-multi": "2"],
        body: bytes.map { ByteBuffer(repeating: 7, count: $0) } ?? ByteBuffer(string: body),
        varyingRequestHeaders: ["Accept-Language": "en"],
        requestTime: Date(timeIntervalSince1970: 1_700_000_000.25),
        responseTime: Date(timeIntervalSince1970: 1_700_000_001.5),
        isForced: isForced
    )
}

func expectEqual(_ actual: CachedResponse?, _ expected: CachedResponse) {
    #expect(actual?.status == expected.status)
    #expect(actual?.status.reasonPhrase == expected.status.reasonPhrase)
    #expect(actual.map { Array($0.headers) }.map { $0.map(\.name) } == expected.headers.map(\.name))
    #expect(
        actual.map { Array($0.headers) }.map { $0.map(\.value) } == expected.headers.map(\.value)
    )
    #expect(actual?.body == expected.body)
    #expect(actual?.varyingRequestHeaders == expected.varyingRequestHeaders)
    #expect(actual?.requestTime == expected.requestTime)
    #expect(actual?.responseTime == expected.responseTime)
    #expect(actual?.isForced == expected.isForced)
}

func makeTemporaryDirectory() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("netskein-cache-\(UUID().uuidString)")
        .path
}

func removeDirectory(_ directory: String?) {
    if let directory { try? FileManager.default.removeItem(atPath: directory) }
}

extension CachedResponse {
    var bodyText: String { String(buffer: body) }
}
