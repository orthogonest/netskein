import AsyncHTTPClient
import NIOCore

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

enum BodySource: Sendable {
    case none
    case bytes(ByteBuffer)
    case file(path: String, chunkSize: Int, onProgress: UploadProgress?)
}

extension BodySource {
    var bodyDescription: RequestBodyDescription {
        switch self {
        case .none: return .none
        case let .bytes(buffer): return .bytes(buffer)
        case let .file(path, _, _): return .file(path: path)
        }
    }

    func makeBody() throws(NetSkeinError) -> HTTPClientRequest.Body? {
        switch self {
        case .none:
            return nil

        case let .bytes(buffer):
            return .bytes(buffer)

        case let .file(path, chunkSize, onProgress):
            // Opened per attempt, so Content-Length always matches the bytes actually streamed
            let chunks = try FileChunkSequence(
                path: path,
                chunkSize: chunkSize,
                onProgress: onProgress
            )

            return .stream(chunks, length: .known(chunks.fileSize))
        }
    }
}
