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
    case file(path: String, chunkSize: Int, fileSize: Int64, onProgress: UploadProgress?)
}

extension BodySource {
    func makeBody() throws(NetSkeinError) -> HTTPClientRequest.Body? {
        switch self {
        case .none:
            return nil

        case let .bytes(buffer):
            return .bytes(buffer)

        case let .file(path, chunkSize, fileSize, onProgress):
            guard let fileHandle = FileHandle(forReadingAtPath: path) else {
                throw .custom(kind: .ioFailure, message: "Unable to open file at path: \(path)")
            }

            let stream = AsyncStream<ByteBuffer> { continuation in
                continuation.onTermination = { _ in
                    try? fileHandle.close()
                }

                Task {
                    var sentBytes: Int64 = 0
                    do {
                        while true {
                            guard
                                let data = try fileHandle.read(upToCount: chunkSize),
                                !data.isEmpty
                            else {
                                continuation.finish()
                                break
                            }
                            let allocator = ByteBufferAllocator()
                            var buffer = allocator.buffer(capacity: data.count)
                            buffer.writeBytes(data)
                            continuation.yield(buffer)
                            sentBytes += Int64(data.count)
                            onProgress?(sentBytes, fileSize)
                        }
                    } catch {
                        continuation.finish()
                    }
                }
            }

            return .stream(stream, length: .known(fileSize))
        }
    }
}
