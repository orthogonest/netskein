import NIOCore
import Testing

@testable import NetSkein

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct MemoryCacheStorageTests {
    func entry(bytes: Int) -> CachedResponse {
        CachedResponse(
            status: .ok,
            headers: [:],
            body: ByteBuffer(repeating: 0, count: bytes),
            varyingRequestHeaders: [:],
            requestTime: Date(timeIntervalSince1970: 0),
            responseTime: Date(timeIntervalSince1970: 0),
            isForced: false
        )
    }
}

extension MemoryCacheStorageTests {
    @Test("MemoryCacheStorageTests: Verifies stored entries are returned and replaced per URL")
    func testStoreAndReplace() async {
        let storage = MemoryCacheStorage(maxBytes: 100)

        await storage.store([entry(bytes: 10), entry(bytes: 20)], for: "a")
        #expect(await storage.entries(for: "a").count == 2)

        await storage.store([entry(bytes: 30)], for: "a")
        #expect(await storage.entries(for: "a").map(\.body.readableBytes) == [30])
        #expect(await storage.entries(for: "missing").isEmpty)
    }

    @Test("MemoryCacheStorageTests: Verifies the least recently used URL is evicted first")
    func testEvictsLeastRecentlyUsed() async {
        let storage = MemoryCacheStorage(maxBytes: 100)
        await storage.store([entry(bytes: 40)], for: "a")
        await storage.store([entry(bytes: 40)], for: "b")

        // Reading "a" makes "b" the least recently used
        _ = await storage.entries(for: "a")
        await storage.store([entry(bytes: 40)], for: "c")

        #expect(await storage.entries(for: "a").count == 1)
        #expect(await storage.entries(for: "b").isEmpty)
        #expect(await storage.entries(for: "c").count == 1)
    }

    @Test(
        "MemoryCacheStorageTests: Verifies entries larger than the limit, or empty ones, are dropped"
    )
    func testRejectsOversizedAndEmpty() async {
        let storage = MemoryCacheStorage(maxBytes: 10)
        await storage.store([entry(bytes: 5)], for: "a")

        await storage.store([entry(bytes: 11)], for: "a")
        #expect(await storage.entries(for: "a").isEmpty)

        await storage.store([entry(bytes: 5)], for: "b")
        await storage.store([], for: "b")
        #expect(await storage.entries(for: "b").isEmpty)

        // The freed bytes are available again
        await storage.store([entry(bytes: 10)], for: "c")
        #expect(await storage.entries(for: "c").count == 1)
    }

    @Test("MemoryCacheStorageTests: Verifies remove and removeAll free their entries")
    func testRemove() async {
        let storage = MemoryCacheStorage(maxBytes: 10)
        await storage.store([entry(bytes: 5)], for: "a")
        await storage.store([entry(bytes: 5)], for: "b")

        await storage.remove(url: "a")
        await storage.remove(url: "missing")
        #expect(await storage.entries(for: "a").isEmpty)

        await storage.removeAll()
        #expect(await storage.entries(for: "b").isEmpty)

        await storage.store([entry(bytes: 10)], for: "c")
        #expect(await storage.entries(for: "c").count == 1)
    }
}
