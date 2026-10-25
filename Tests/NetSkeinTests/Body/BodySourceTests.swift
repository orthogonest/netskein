import AsyncHTTPClient
import Foundation
import NIOConcurrencyHelpers
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

    @Test("BodySourceTests: Verifies makeBody does not read the file or report progress eagerly")
    func testMakeBodyFileIsLazy() throws {
        let tempURL = try createTempFile(size: 100)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let progressEvents = NIOLockedValueBox<[Int64]>([])
        let source = BodySource.file(
            path: tempURL.path,
            chunkSize: 30,
            onProgress: { sent, _ in
                progressEvents.withLockedValue { $0.append(sent) }
            }
        )

        let body = try source.makeBody()

        // Chunks are read only when the transport pulls them (see FileChunkSequenceTests)
        #expect(body != nil)
        #expect(progressEvents.withLockedValue { $0 }.isEmpty)
    }

    @Test("BodySourceTests: Verifies makeBody works when onProgress is nil")
    func testMakeBodyFileWithoutProgress() async throws {
        let tempURL = try createTempFile(size: 64)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let source = BodySource.file(
            path: tempURL.path,
            chunkSize: 32,
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
}
