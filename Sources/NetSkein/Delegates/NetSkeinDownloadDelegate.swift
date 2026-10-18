import AsyncHTTPClient
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

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

    public func didReceiveHead(
        task: HTTPClient.Task<Response>,
        _ head: HTTPResponseHead
    ) -> EventLoopFuture<Void> {
        responseHead.withLockedValue { responseHead in responseHead = head }

        guard head.status.code >= 200 && head.status.code < 300 else {
            return task.eventLoop.makeFailedFuture(NetSkeinError.badStatus(head.status))
        }

        return task.eventLoop.makeSucceededVoidFuture()
    }

    public func didReceiveBodyPart(
        task: HTTPClient.Task<Response>,
        _ buffer: ByteBuffer
    ) -> EventLoopFuture<Void> {
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
                let ioError = NetSkeinError.custom(
                    kind: .ioFailure,
                    message:
                        "Disk write failed during streaming body allocation: \(error.localizedDescription)",
                    underlyingError: error
                )
                return task.eventLoop.makeFailedFuture(ioError)
            }
        }
    }

    public func didFinishRequest(
        task _: HTTPClient.Task<Response>
    ) throws(NetSkeinError) -> Response {
        do {
            try fileHandle.close()
        } catch {
            throw NetSkeinError.custom(
                kind: .ioFailure,
                message: "Failed to securely close and flush the downloaded file handle on disk.",
                underlyingError: error
            )
        }

        guard let head = responseHead.withLockedValue({ $0 }) else {
            throw .simple(.emptyResponseBody)
        }

        return head
    }

    public func didReceiveError(task _: HTTPClient.Task<Response>, _: any Error) {
        try? fileHandle.close()
    }
}
