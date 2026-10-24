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

        // yield is synchronous, so events keep the exact order BodySource reports them
        let (events, eventsContinuation) = AsyncStream.makeStream(
            of: (sent: Int64, total: Int64).self
        )

        let source = BodySource.file(
            path: tempURL.path,
            chunkSize: chunkSize,
            fileSize: fileSize,
            onProgress: { sent, total in
                eventsContinuation.yield((sent, total))
                if sent >= fileSize { eventsContinuation.finish() }
            }
        )

        let body = try source.makeBody()
        #expect(body != nil)

        let recordedEvents = try await withThrowingTimeout(seconds: 3) {
            var collected: [(sent: Int64, total: Int64)] = []
            for await event in events { collected.append(event) }
            return collected
        }

        #expect(recordedEvents.map(\.sent) == [30, 60, 90, 100])
        #expect(recordedEvents.allSatisfy { $0.total == fileSize })
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
    private func createTempFile(size: Int) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("BodySourceTest_\(UUID().uuidString).bin")
        let data = Data(repeating: 0x42, count: size)  // 'B'
        try data.write(to: fileURL)
        return fileURL
    }

    private func withThrowingTimeout(
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

    private func withThrowingTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw TimeoutError()
            }
            return result
        }
    }
}

private struct TimeoutError: Error {}
