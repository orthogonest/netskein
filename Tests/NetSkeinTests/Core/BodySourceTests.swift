import AsyncHTTPClient
import Foundation
import NIOCore
import Testing

@testable import NetSkein

struct BodySourceTests {
    @Test("BodySourceTests: Verifies makeBody returns nil for .none case")
    func testMakeBodyNone() throws {
        let source = BodySource.none
        let body = try source.makeBody()
        #expect(body == nil)
    }

    @Test("BodySourceTests: Verifies makeBody returns body for .bytes case")
    func testMakeBodyBytes() throws {
        var buffer = ByteBufferAllocator().buffer(capacity: 32)
        buffer.writeString("Hello, NetSkein streaming body!")

        let source = BodySource.bytes(buffer)
        let body = try source.makeBody()

        #expect(body != nil)
    }

    @Test("BodySourceTests: Verifies makeBody throws ioFailure when file does not exist")
    func testMakeBodyFileNotFound() throws {
        let nonExistentPath = "/tmp/netskein_non_existent_\(UUID().uuidString).bin"
        let source = BodySource.file(
            path: nonExistentPath,
            chunkSize: 1024,
            fileSize: 100,
            onProgress: nil
        )

        #expect(throws: NetSkeinError.self) {
            try source.makeBody()
        }

        do {
            _ = try source.makeBody()
            Issue.record("Expected makeBody to throw .ioFailure error")
        } catch {
            #expect(error.kind == .ioFailure)
        }
    }

    @Test("BodySourceTests: Verifies makeBody reads multiple chunks and reports upload progress")
    func testMakeBodyFileStreamingWithProgress() async throws {
        let fileSize: Int64 = 100
        let chunkSize = 30  // Will produce 4 chunks: 30, 30, 30, 10 bytes
        let tempURL = try createTempFile(size: Int(fileSize))
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let tracker = ProgressTracker(targetBytes: fileSize)

        let source = BodySource.file(
            path: tempURL.path,
            chunkSize: chunkSize,
            fileSize: fileSize,
            onProgress: { sent, total in
                Task {
                    await tracker.record(sent: sent, total: total)
                }
            }
        )

        let body = try source.makeBody()
        #expect(body != nil)

        // Wait until the background stream Task processes the file and emits progress
        try await withThrowingTimeout(seconds: 3) {
            await tracker.waitForCompletion()
        }

        let recordedEvents = await tracker.getRecords()
        #expect(!recordedEvents.isEmpty)

        // Verify incremental byte progress
        let lastEvent = try #require(recordedEvents.last)
        #expect(lastEvent.sent == fileSize)
        #expect(lastEvent.total == fileSize)

        // Verify chunk step counts (30, 60, 90, 100)
        let expectedSentValues: [Int64] = [30, 60, 90, 100]
        let actualSentValues = recordedEvents.map(\.sent)
        #expect(actualSentValues == expectedSentValues)
    }

    @Test("BodySourceTests: Verifies makeBody works when onProgress is nil")
    func testMakeBodyFileWithoutProgress() async throws {
        let tempURL = try createTempFile(size: 64)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let source = BodySource.file(
            path: tempURL.path,
            chunkSize: 32,
            fileSize: 64,
            onProgress: nil  // Explicit nil branch
        )

        let body = try source.makeBody()
        #expect(body != nil)
    }

    @Test("BodySourceTests: Verifies makeBody handles empty 0-byte file")
    func testMakeBodyEmptyFile() async throws {
        let tempURL = try createTempFile(size: 0)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let source = BodySource.file(
            path: tempURL.path,
            chunkSize: 1024,
            fileSize: 0,
            onProgress: nil
        )

        let body = try source.makeBody()
        #expect(body != nil)
    }
}

// MARK: - Test Helpers

extension BodySourceTests {
    fileprivate func createTempFile(size: Int) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("BodySourceTest_\(UUID().uuidString).bin")
        let data = Data(repeating: 0x42, count: size)  // 'B'
        try data.write(to: fileURL)
        return fileURL
    }

    fileprivate func withThrowingTimeout(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            try await group.next()
            group.cancelAll()
        }
    }
}

private struct TimeoutError: Error {}

/// Thread-safe actor to collect asynchronous upload progress events in tests
private actor ProgressTracker {
    private var records: [(sent: Int64, total: Int64)] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private let targetBytes: Int64

    init(targetBytes: Int64) {
        self.targetBytes = targetBytes
    }

    func record(sent: Int64, total: Int64) {
        records.append((sent, total))
        if sent >= targetBytes {
            continuation?.resume()
            continuation = nil
        }
    }

    func waitForCompletion() async {
        if let last = records.last, last.sent >= targetBytes {
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func getRecords() -> [(sent: Int64, total: Int64)] {
        records
    }
}
