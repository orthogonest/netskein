#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

import AsyncHTTPClient
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1

public final class NetSkeinDownloadDelegate: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let eventLoop: EventLoop
    private let lock: NIOLock
    private var responseHead: HTTPResponseHead?

    public init(fileHandle: FileHandle, eventLoop: EventLoop) {
        self.fileHandle = fileHandle
        self.eventLoop = eventLoop
        lock = NIOLock()
    }
}

extension NetSkeinDownloadDelegate: HTTPClientResponseDelegate {
    public typealias Response = HTTPResponseHead

    public func didReceiveHead(task: HTTPClient.Task<Response>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        lock.withLock {
            self.responseHead = head
        }

        guard head.status == .ok else {
            return task.eventLoop.makeFailedFuture(NetSkeinError.badStatus(head.status))
        }

        return task.eventLoop.makeSucceededVoidFuture()
    }

    public func didReceiveBodyPart(task: HTTPClient.Task<Response>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        var mutableBuffer = buffer
        guard let data = mutableBuffer.readData(length: mutableBuffer.readableBytes) else {
            return task.eventLoop.makeSucceededVoidFuture()
        }

        do {
            try fileHandle.write(contentsOf: data)
            return task.eventLoop.makeSucceededVoidFuture()
        } catch {
            return task.eventLoop.makeFailedFuture(error)
        }
    }

    public func didFinishRequest(task _: HTTPClient.Task<Response>) throws -> Response {
        try fileHandle.close()

        guard let head = lock.withLock({ self.responseHead }) else {
            throw NetSkeinError.emptyResponseBody
        }

        return head
    }

    public func didReceiveError(task _: HTTPClient.Task<Response>, _: any Error) {
        try? fileHandle.close()
    }
}
