import NIOCore
import NIOHTTP1
import NetSkeinTesting
import Testing

@testable import NetSkein

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct DiskCacheStorageTests {
    let url = "https://api.example.com/items"

    func path(in directory: String, for url: String) -> String {
        directory + "/" + DiskCacheStorage.fileName(for: url)
    }
}

// MARK: - File Format

extension DiskCacheStorageTests {
    @Test("DiskCacheStorageTests: the file format round-trips every field")
    func testCodecRoundTrip() throws {
        let entries = [sampleEntry(body: "a", isForced: true), sampleEntry(body: "b")]

        let decoded = try #require(CacheFileCodec.decode(CacheFileCodec.encode(entries, url: url)))

        #expect(decoded.url == url)
        #expect(decoded.entries.count == 2)
        expectEqual(decoded.entries.first, entries[0])
        expectEqual(decoded.entries.last, entries[1])
    }

    @Test("DiskCacheStorageTests: truncated, padded or foreign files do not decode")
    func testCodecRejectsBadFiles() {
        let encoded = CacheFileCodec.encode([sampleEntry(body: "a")], url: url)

        for length in 0..<encoded.readableBytes {
            let truncated = encoded.getSlice(at: 0, length: length) ?? ByteBuffer()
            #expect(CacheFileCodec.decode(truncated) == nil, "decoded \(length) bytes")
        }

        var padded = encoded
        padded.writeInteger(UInt8(0))
        #expect(CacheFileCodec.decode(padded) == nil)

        var otherVersion = encoded
        otherVersion.setInteger(CacheFileCodec.version + 1, at: 4)
        #expect(CacheFileCodec.decode(otherVersion) == nil)

        #expect(CacheFileCodec.decode(ByteBuffer(string: "not a cache file")) == nil)
    }

    @Test("DiskCacheStorageTests: file names are stable hashes of the URL")
    func testFileName() {
        let name = DiskCacheStorage.fileName(for: url)

        #expect(name == DiskCacheStorage.fileName(for: url))
        #expect(name != DiskCacheStorage.fileName(for: url + "?page=2"))
        #expect(name.hasSuffix(".cache"))
    }

    @Test("DiskCacheStorageTests: files without a size or modification date are skipped")
    func testStoredFileAttributes() {
        let valid = DiskCacheStorage.StoredFile(
            name: "a.cache",
            attributes: [.size: 10, .modificationDate: Date(timeIntervalSince1970: 0)]
        )

        #expect(valid?.bytes == 10)
        #expect(DiskCacheStorage.StoredFile(name: "a.cache", attributes: [:]) == nil)
    }
}

// MARK: - Persistence

extension DiskCacheStorageTests {
    @Test("DiskCacheStorageTests: entries survive a new storage on the same directory")
    func testPersistsAcrossInstances() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let entry = sampleEntry(body: "kept", isForced: true)

        try await DiskCacheStorage(directory: directory, maxBytes: 10_000).store([entry], for: url)
        let reopened = try DiskCacheStorage(directory: directory, maxBytes: 10_000)

        expectEqual(await reopened.entries(for: url).first, entry)
    }

    @Test("DiskCacheStorageTests: after a restart, files are evicted oldest modified first")
    func testRestartEvictionOrder() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let first = try DiskCacheStorage(directory: directory, maxBytes: 2_500)
        await first.store([sampleEntry(bytes: 1_000)], for: "https://x/old")
        await first.store([sampleEntry(bytes: 1_000)], for: "https://x/new")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: path(in: directory, for: "https://x/old")
        )

        let reopened = try DiskCacheStorage(directory: directory, maxBytes: 2_500)
        await reopened.store([sampleEntry(bytes: 1_000)], for: "https://x/third")

        #expect(await reopened.entries(for: "https://x/old").isEmpty)
        #expect(await reopened.entries(for: "https://x/new").count == 1)
    }

    @Test("DiskCacheStorageTests: concurrent first lookups build one consistent index")
    func testConcurrentFirstUse() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        try await DiskCacheStorage(directory: directory, maxBytes: 10_000)
            .store([sampleEntry(body: "shared")], for: url)
        let reopened = try DiskCacheStorage(directory: directory, maxBytes: 10_000)

        let bodies = await withTaskGroup(of: [String].self) { group in
            for _ in 0..<16 {
                group.addTask { await reopened.entries(for: url).map(\.bodyText) }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }

        #expect(bodies == Array(repeating: "shared", count: 16))
    }
}

// MARK: - Bad Files and Failures

extension DiskCacheStorageTests {
    @Test("DiskCacheStorageTests: an unreadable file is a miss and is deleted")
    func testCorruptFile() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let storage = try DiskCacheStorage(directory: directory, maxBytes: 10_000)
        let file = path(in: directory, for: url)
        FileManager.default.createFile(atPath: file, contents: Data("garbage".utf8))

        #expect(await storage.entries(for: url).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @Test("DiskCacheStorageTests: a file belonging to another URL is a miss and is kept")
    func testHashCollision() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let storage = try DiskCacheStorage(directory: directory, maxBytes: 10_000)
        let file = path(in: directory, for: url)
        let other = CacheFileCodec.encode(
            [sampleEntry(body: "other")],
            url: "https://other.example"
        )
        FileManager.default.createFile(atPath: file, contents: Data(other.readableBytesView))

        #expect(await storage.entries(for: url).isEmpty)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test("DiskCacheStorageTests: a file deleted behind the storage's back is a miss")
    func testFileDeletedExternally() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let storage = try DiskCacheStorage(directory: directory, maxBytes: 10_000)
        await storage.store([sampleEntry(body: "gone")], for: url)
        try FileManager.default.removeItem(atPath: path(in: directory, for: url))

        #expect(await storage.entries(for: url).isEmpty)
    }

    @Test("DiskCacheStorageTests: removeAll only deletes cache files")
    func testRemoveAllKeepsOtherFiles() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let storage = try DiskCacheStorage(directory: directory, maxBytes: 10_000)
        await storage.store([sampleEntry(body: "a")], for: url)
        FileManager.default.createFile(atPath: directory + "/notes.txt", contents: Data())

        await storage.removeAll()

        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
        #expect(remaining == [".partial", "notes.txt"])
    }

    @Test("DiskCacheStorageTests: creating the storage fails when the directory cannot exist")
    func testInitThrows() throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: directory + "/file", contents: Data())

        #expect(throws: (any Error).self) {
            _ = try DiskCacheStorage(directory: directory + "/file/cache", maxBytes: 10_000)
        }
    }

    @Test(
        "DiskCacheStorageTests: a directory that cannot be used makes every operation a quiet no-op"
    )
    func testDirectoryUnusable() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let storage = try DiskCacheStorage(directory: directory, maxBytes: 10_000)
        removeDirectory(directory)
        FileManager.default.createFile(atPath: directory, contents: Data())

        #expect(await storage.entries(for: url).isEmpty)
        await storage.store([sampleEntry(body: "lost")], for: url)
        #expect(await storage.entries(for: url).isEmpty)
        await storage.removeAll()
    }
}

// MARK: - With HTTPCache

extension DiskCacheStorageTests {
    @Test("DiskCacheStorageTests: a cached response is served again after a restart")
    func testHTTPCacheAcrossRestart() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let clock = TestClock()
        let transport = ScriptedTransport([
            .response(.ok, ["Cache-Control": "max-age=60"], body: "from disk")
        ])

        let before = makeClient(
            transport,
            cache: makeCache(
                clock: clock,
                storage: try DiskCacheStorage(directory: directory, maxBytes: 10_000)
            )
        )
        _ = try await before.get(itemsURL).send()

        clock.advance(by: .seconds(10))
        let after = makeClient(
            transport,
            cache: makeCache(
                clock: clock,
                storage: try DiskCacheStorage(directory: directory, maxBytes: 10_000)
            )
        )
        let response = try await after.get(itemsURL).send()

        #expect(response.cacheStatus == "hit")
        #expect(response.text() == "from disk")
        #expect(response.headers.first(name: "Age") == "10")
        #expect(transport.requests.count == 1)
    }
}

// MARK: - Robustness

extension DiskCacheStorageTests {
    @Test("DiskCacheStorageTests: cancelled lookups neither hide nor delete stored entries")
    func testCancelledLookups() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        try await DiskCacheStorage(directory: directory, maxBytes: 10_000)
            .store([sampleEntry(body: "kept")], for: url)
        let reopened = try DiskCacheStorage(directory: directory, maxBytes: 10_000)

        // The first lookup builds the index; the second reads the file
        for _ in 0..<2 {
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await reopened.entries(for: url).map(\.bodyText)
            }
            #expect(await cancelled.value == ["kept"])
        }

        #expect(await reopened.entries(for: url).map(\.bodyText) == ["kept"])
        #expect(FileManager.default.fileExists(atPath: path(in: directory, for: url)))
    }

    @Test("DiskCacheStorageTests: a file larger than the limit is discarded without being read")
    func testOversizedForeignFile() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        let file = path(in: directory, for: url)
        FileManager.default.createFile(atPath: file, contents: Data(repeating: 0, count: 1_000))

        let storage = try DiskCacheStorage(directory: directory, maxBytes: 100)

        #expect(await storage.entries(for: url).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @Test("DiskCacheStorageTests: partial files left by a crash are cleared on first use")
    func testClearsPartialFiles() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let partial = directory + "/.partial"
        try FileManager.default.createDirectory(atPath: partial, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: partial + "/abc.cache.7",
            contents: Data("half".utf8)
        )

        let storage = try DiskCacheStorage(directory: directory, maxBytes: 10_000)
        _ = await storage.entries(for: url)

        #expect(try FileManager.default.contentsOfDirectory(atPath: partial).isEmpty)
    }

    @Test("DiskCacheStorageTests: a write that cannot be put in place leaves no partial file")
    func testFailedRename() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let storage = try DiskCacheStorage(directory: directory, maxBytes: 10_000)
        _ = await storage.entries(for: url)
        // A directory where the file should go makes the rename fail
        try FileManager.default.createDirectory(
            atPath: path(in: directory, for: url),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: path(in: directory, for: url) + "/keep",
            contents: Data()
        )

        await storage.store([sampleEntry(body: "blocked")], for: url)

        #expect(await storage.entries(for: url).isEmpty)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory + "/.partial").isEmpty
        )
    }
}
