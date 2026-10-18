import AsyncHTTPClient
import NIOCore

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct ChunkStreamer {
    let fileHandle: FileHandle
    let chunkSize: Int
    let eventLoop: EventLoop
}

extension ChunkStreamer {
    func readAndWrite(using writer: HTTPClient.Body.StreamWriter) -> EventLoopFuture<Void> {
        do {
            guard let data = try fileHandle.read(upToCount: chunkSize), !data.isEmpty else {
                try fileHandle.close()
                return eventLoop.makeSucceededFuture(())
            }

            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)

            return writer.write(.byteBuffer(buffer)).flatMap { self.readAndWrite(using: writer) }
        } catch {
            try? fileHandle.close()
            return eventLoop.makeFailedFuture(error)
        }
    }
}
