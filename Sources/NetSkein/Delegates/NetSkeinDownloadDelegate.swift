#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

import AsyncHTTPClient
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1

public final class NetSkeinDownloadDelegate: Sendable {
    private let fileHandle: FileHandle
    private let eventLoop: EventLoop
    private let responseHead: NIOLockedValueBox<HTTPResponseHead?>

    public init(fileHandle: FileHandle, eventLoop: EventLoop) {
        self.fileHandle = fileHandle
        self.eventLoop = eventLoop
        responseHead = NIOLockedValueBox(nil)
    }
}

extension NetSkeinDownloadDelegate: HTTPClientResponseDelegate {
    public typealias Response = HTTPResponseHead

    public func didReceiveHead(task: HTTPClient.Task<Response>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        responseHead.withLockedValue { responseHead in
            responseHead = head
        }

        guard head.status == .ok else {
            return task.eventLoop.makeFailedFuture(NetSkeinError.badStatus(head.status))
        }

        return task.eventLoop.makeSucceededVoidFuture()
    }

    public func didReceiveBodyPart(task: HTTPClient.Task<Response>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        buffer.withUnsafeReadableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return task.eventLoop.makeSucceededVoidFuture()
            }

            let data = Data(
                bytesNoCopy: UnsafeMutableRawPointer(mutating: baseAddress),
                count: bytes.count,
                deallocator: .none
            )

            do {
                try fileHandle.write(contentsOf: data)
                return task.eventLoop.makeSucceededVoidFuture()
            } catch {
                return task.eventLoop.makeFailedFuture(error)
            }
        }
    }

    public func didFinishRequest(task _: HTTPClient.Task<Response>) throws -> Response {
        try fileHandle.close()

        guard let head = responseHead.withLockedValue({ $0 }) else {
            throw NetSkeinError.emptyResponseBody
        }

        return head
    }

    public func didReceiveError(task _: HTTPClient.Task<Response>, _: any Error) {
        try? fileHandle.close()
    }
}
