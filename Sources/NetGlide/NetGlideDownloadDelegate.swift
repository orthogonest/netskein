import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

public final class NetGlideDownloadDelegate: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let eventLoop: EventLoop
    private let mutex: Mutex
    private var responseHead: HTTPResponseHead?

    public init(fileHandle: FileHandle, eventLoop: EventLoop) {
        self.fileHandle = fileHandle
        self.eventLoop = eventLoop
        mutex = Mutex()
    }
}

extension NetGlideDownloadDelegate: HTTPClientResponseDelegate {
    public typealias Response = HTTPResponseHead

    public func didReceiveHead(task: HTTPClient.Task<Response>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        mutex.withLock {
            self.responseHead = head
        }

        guard head.status == .ok else {
            return task.eventLoop.makeFailedFuture(NetGlideError.badStatus(head.status))
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

        guard let head = mutex.withLock({ self.responseHead }) else {
            throw NetGlideError.emptyResponseBody
        }

        return head
    }

    public func didReceiveError(task _: HTTPClient.Task<Response>, _: any Error) {
        try? fileHandle.close()
    }
}
