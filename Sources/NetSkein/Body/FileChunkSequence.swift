import NIOCore

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Streams a file as a request body, reading one chunk per `next()` call.
///
/// The transport pulls the next chunk only after it has accepted the previous one, so at most
/// one chunk is held in memory regardless of file size, and a slow network naturally pauses
/// disk reads. The sequence shares a single file handle, so it supports one iteration only.
struct FileChunkSequence: Sendable {
    let fileHandle: FileHandle
    let chunkSize: Int
    let fileSize: Int64
    let onProgress: UploadProgress?
}

extension FileChunkSequence {
    /// Opens `path` and measures the opened handle, so the reported size always matches the
    /// bytes that will be streamed, including through symlinks and for files changed since
    /// the request was built.
    init(path: String, chunkSize: Int, onProgress: UploadProgress?) throws(NetSkeinError) {
        guard let fileHandle = FileHandle(forReadingAtPath: path) else {
            throw .custom(kind: .ioFailure, message: "Unable to open file at path: \(path)")
        }

        let fileSize: Int64
        do {
            fileSize = Int64(clamping: try fileHandle.seekToEnd())
            try fileHandle.seek(toOffset: 0)
        } catch {
            try? fileHandle.close()
            throw .custom(
                kind: .ioFailure,
                message: "Unable to determine size of file at path: \(path)",
                underlyingError: error
            )
        }

        self.init(
            fileHandle: fileHandle,
            chunkSize: chunkSize,
            fileSize: fileSize,
            onProgress: onProgress
        )
    }
}

extension FileChunkSequence: AsyncSequence {
    typealias Element = ByteBuffer

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            fileHandle: fileHandle,
            chunkSize: chunkSize,
            fileSize: fileSize,
            onProgress: onProgress
        )
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        let fileHandle: FileHandle
        let chunkSize: Int
        let fileSize: Int64
        let onProgress: UploadProgress?

        private var sentBytes: Int64 = 0
        private var pendingBytes: Int64 = 0

        init(
            fileHandle: FileHandle,
            chunkSize: Int,
            fileSize: Int64,
            onProgress: UploadProgress?
        ) {
            self.fileHandle = fileHandle
            self.chunkSize = chunkSize
            self.fileSize = fileSize
            self.onProgress = onProgress
        }

        mutating func next() async throws -> ByteBuffer? {
            // Being asked for another chunk means the transport accepted the previous one
            if pendingBytes > 0 {
                sentBytes += pendingBytes
                pendingBytes = 0
                onProgress?(sentBytes, fileSize)
            }

            try Task.checkCancellation()

            let data: Data?
            do {
                data = try fileHandle.read(upToCount: chunkSize)
            } catch {
                try? fileHandle.close()
                throw NetSkeinError.custom(
                    kind: .ioFailure,
                    message: "Failed reading upload file chunk: \(error.localizedDescription)",
                    underlyingError: error
                )
            }

            guard let data, !data.isEmpty else {
                try? fileHandle.close()
                return nil
            }

            pendingBytes = Int64(data.count)
            return ByteBuffer(bytes: data)
        }
    }
}
