import NIOCore

/// Reports the progress of a ``NetSkeinRequest/file(atPath:chunkSize:onProgress:)`` upload.
///
/// Called each time the transport accepts a chunk of the file, with the bytes sent so far and
/// the file's size.
public typealias UploadProgress = @Sendable (_ bytesTransferred: Int64, _ bytesTotal: Int64) -> Void
/// Reports the progress of a ``NetSkeinRequest/download(toFileAtPath:resumption:onProgress:)``.
///
/// Called after each chunk is written, with the bytes in the file so far and the expected total,
/// or `nil` when the server doesn't send one. When a download resumes, both include the bytes
/// already on disk.
public typealias DownloadProgress =
    @Sendable (
        _ bytesTransferred: Int64,
        _ bytesTotal: Int64?
    ) -> Void
/// Receives each chunk of a response body from ``NetSkeinRequest/stream(_:)``.
///
/// Called with the chunk, the bytes received so far, and the total from `Content-Length`, or
/// `nil` when the server doesn't send one. The next chunk is read only after the handler
/// returns. An error it throws ends the call with kind ``NetSkeinError/Kind/clientError`` and
/// is never retried.
public typealias ChunkHandler =
    @Sendable (
        _ chunk: ByteBuffer,
        _ bytesTransferred: Int64,
        _ bytesTotal: Int64?
    ) async throws -> Void
