import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Testing

@testable import NetSkein

struct FileChunkSequenceTests {
    @Test(
        "FileChunkSequenceTests: Verifies one chunk is read per pull and progress counts only accepted chunks"
    )
    func testReadsLazilyAndReportsAcceptedBytes() async throws {
        let content = Data((0..<100).map { UInt8($0) })
        let tempURL = try createTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let fileHandle = try #require(FileHandle(forReadingAtPath: tempURL.path))
        let progressEvents = NIOLockedValueBox<[(sent: Int64, total: Int64)]>([])
        let sequence = FileChunkSequence(
            fileHandle: fileHandle,
            chunkSize: 30,
            fileSize: 100,
            onProgress: { sent, total in
                progressEvents.withLockedValue { $0.append((sent, total)) }
            }
        )

        var iterator = sequence.makeAsyncIterator()
        #expect(try fileHandle.offset() == 0)

        var received = Data()
        var expectedSent: [Int64] = []
        for (expectedOffset, previouslyAccepted) in [(30, nil), (60, 30), (90, 60), (100, 90)] {
            let chunk = try #require(try await iterator.next())
            received.append(contentsOf: chunk.readableBytesView)

            // Only the chunk just handed out has been read from disk
            #expect(try fileHandle.offset() == UInt64(expectedOffset))

            // The handed-out chunk is not reported until the transport asks for the next one
            if let previouslyAccepted { expectedSent.append(Int64(previouslyAccepted)) }
            #expect(progressEvents.withLockedValue { $0 }.map(\.sent) == expectedSent)
        }

        #expect(try await iterator.next() == nil)
        #expect(received == content)
        #expect(progressEvents.withLockedValue { $0 }.map(\.sent) == [30, 60, 90, 100])
        #expect(progressEvents.withLockedValue { $0 }.allSatisfy { $0.total == 100 })
    }

    @Test("FileChunkSequenceTests: Verifies an empty file ends immediately without progress")
    func testEmptyFileEndsImmediately() async throws {
        let tempURL = try createTempFile(content: Data())
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let progressEvents = NIOLockedValueBox<[Int64]>([])
        let sequence = FileChunkSequence(
            fileHandle: try #require(FileHandle(forReadingAtPath: tempURL.path)),
            chunkSize: 1024,
            fileSize: 0,
            onProgress: { sent, _ in
                progressEvents.withLockedValue { $0.append(sent) }
            }
        )

        var iterator = sequence.makeAsyncIterator()

        #expect(try await iterator.next() == nil)
        #expect(progressEvents.withLockedValue { $0 }.isEmpty)
    }

    @Test("FileChunkSequenceTests: Verifies a disk read failure is wrapped as ioFailure")
    func testReadFailureThrowsIOFailure() async throws {
        // open(2) accepts a directory for reading, but read() on it fails with EISDIR
        let directoryFD = open(FileManager.default.temporaryDirectory.path, O_RDONLY)
        try #require(directoryFD >= 0)
        let directoryHandle = FileHandle(fileDescriptor: directoryFD, closeOnDealloc: true)
        let sequence = FileChunkSequence(
            fileHandle: directoryHandle,
            chunkSize: 1024,
            fileSize: 1024,
            onProgress: nil
        )

        var iterator = sequence.makeAsyncIterator()

        do {
            _ = try await iterator.next()
            Issue.record("Expected next() to throw .ioFailure when reading fails")
        } catch let error as NetSkeinError {
            #expect(error.kind == .ioFailure)
            #expect(error.errorDescription?.contains("Failed reading upload file chunk") == true)
        }
    }

    @Test(
        "FileChunkSequenceTests: Verifies a cancelled task stops reading before touching the file"
    )
    func testCancellationStopsReading() async throws {
        let tempURL = try createTempFile(content: Data(repeating: 0x42, count: 64))
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let fileHandle = try #require(FileHandle(forReadingAtPath: tempURL.path))
        let sequence = FileChunkSequence(
            fileHandle: fileHandle,
            chunkSize: 32,
            fileSize: 64,
            onProgress: nil
        )

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var iterator = sequence.makeAsyncIterator()
            return try await iterator.next()
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(try fileHandle.offset() == 0)
    }
}

// MARK: - Opening by Path

extension FileChunkSequenceTests {
    @Test("FileChunkSequenceTests: Verifies a symlink is measured and streamed as its target file")
    func testPathThroughSymlinkUsesTargetSize() async throws {
        let content = Data(repeating: 0x42, count: 100)
        let targetURL = try createTempFile(content: content)
        let linkURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent("FileChunkSequenceLink_\(UUID().uuidString).bin")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        defer {
            try? FileManager.default.removeItem(at: linkURL)
            try? FileManager.default.removeItem(at: targetURL)
        }

        let sequence = try FileChunkSequence(path: linkURL.path, chunkSize: 64, onProgress: nil)

        var streamedBytes = 0
        for try await chunk in sequence { streamedBytes += chunk.readableBytes }

        #expect(sequence.fileSize == 100)
        #expect(streamedBytes == 100)
    }

    @Test(
        "FileChunkSequenceTests: Verifies the size is measured when opened, not when the request was built"
    )
    func testPathMeasuresCurrentFileSize() async throws {
        let fileURL = try createTempFile(content: Data(repeating: 0x42, count: 10))
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // The file grows between building the request and creating the body (e.g. a retry)
        try Data(repeating: 0x43, count: 50).write(to: fileURL)

        let sequence = try FileChunkSequence(path: fileURL.path, chunkSize: 64, onProgress: nil)

        #expect(sequence.fileSize == 50)
    }

    @Test("FileChunkSequenceTests: Verifies a missing path throws ioFailure")
    func testPathMissingFileThrowsIOFailure() {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileChunkSequenceMissing_\(UUID().uuidString).bin").path

        do {
            _ = try FileChunkSequence(path: missingPath, chunkSize: 64, onProgress: nil)
            Issue.record("Expected init(path:) to throw .ioFailure for a missing file")
        } catch {
            #expect(error.kind == .ioFailure)
            #expect(error.errorDescription?.contains("Unable to open file") == true)
        }
    }

    @Test("FileChunkSequenceTests: Verifies an unseekable file throws ioFailure while measuring")
    func testPathUnseekableFileThrowsIOFailure() throws {
        // A named pipe can be opened for reading but not seeked, so measuring its size fails
        let fifoPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileChunkSequenceFIFO_\(UUID().uuidString)").path
        try #require(mkfifo(fifoPath, 0o644) == 0)
        // Holding a writer end open lets the read-only open in init(path:) return immediately
        let writerFD = open(fifoPath, O_RDWR | O_NONBLOCK)
        try #require(writerFD >= 0)
        defer {
            close(writerFD)
            unlink(fifoPath)
        }

        do {
            _ = try FileChunkSequence(path: fifoPath, chunkSize: 64, onProgress: nil)
            Issue.record("Expected init(path:) to throw .ioFailure for an unseekable file")
        } catch {
            #expect(error.kind == .ioFailure)
            #expect(error.errorDescription?.contains("Unable to determine size") == true)
        }
    }
}

// MARK: - Test Helpers

extension FileChunkSequenceTests {
    private func createTempFile(content: Data) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileChunkSequenceTest_\(UUID().uuidString).bin")
        try content.write(to: fileURL)
        return fileURL
    }
}
