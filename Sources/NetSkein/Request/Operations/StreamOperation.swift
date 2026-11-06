import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1

/// Hands each chunk of a successful response to the caller as it arrives.
struct StreamOperation {
    let onChunk: ChunkHandler
    private var _hasDeliveredData: Bool

    // Set here rather than as a property default, which coverage reports as never run
    init(onChunk: @escaping ChunkHandler) {
        self.onChunk = onChunk
        _hasDeliveredData = false
    }
}

extension StreamOperation: RequestOperation {
    typealias Output = (status: HTTPResponseStatus, headers: HTTPHeaders)

    var name: String { "stream" }
    var action: String { "Streaming request" }
    var isBuffered: Bool { false }
    var hasDeliveredData: Bool { _hasDeliveredData }

    func prepareAttempt() -> AttemptSetup {
        AttemptSetup(description: "outbound streaming request")
    }

    mutating func handle(_ response: HTTPClientResponse, logger: Logger) async throws -> Output {
        guard response.status.code >= 200 && response.status.code < 300 else {
            throw NetSkeinError.badStatus(response.status)
        }

        let expectedBytes = response.headers.first(name: "Content-Length").flatMap(Int64.init)
        var receivedBytes: Int64 = 0

        for try await buffer in response.body {
            try checkCancellation()
            receivedBytes += Int64(buffer.readableBytes)
            _hasDeliveredData = true
            do {
                try await onChunk(buffer, receivedBytes, expectedBytes)
            } catch {
                throw NetSkeinError.custom(
                    kind: .clientError,
                    message:
                        "Streaming chunk consumer callback failed: \(error.localizedDescription)",
                    underlyingError: error
                )
            }
        }

        logger.info(
            "Finished streaming response body. Total bytes received: \(receivedBytes)"
        )

        return (response.status, response.headers)
    }
}
