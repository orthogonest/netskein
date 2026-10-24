import NIOCore

public typealias UploadProgress = @Sendable (_ bytesTransferred: Int64, _ bytesTotal: Int64) -> Void
public typealias DownloadProgress =
    @Sendable (
        _ bytesTransferred: Int64,
        _ bytesTotal: Int64?
    ) -> Void
public typealias ChunkHandler =
    @Sendable (
        _ chunk: ByteBuffer,
        _ bytesTransferred: Int64,
        _ bytesTotal: Int64?
    ) async throws -> Void
