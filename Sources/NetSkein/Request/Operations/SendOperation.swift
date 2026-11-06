import AsyncHTTPClient
import Logging
import NIOCore

/// Collects the whole response body in memory.
struct SendOperation {
    let maxResponseBytes: Int
}

extension SendOperation: RequestOperation {
    typealias Output = NetSkeinResponse

    var name: String { "send" }
    var action: String { "Network request" }
    var isBuffered: Bool { true }
    var hasDeliveredData: Bool { false }

    func prepareAttempt() -> AttemptSetup {
        AttemptSetup(description: "outbound network request")
    }

    func handle(_ response: HTTPClientResponse, logger: Logger) async throws -> Output {
        try await NetSkeinResponse(underlyingResponse: response, maxBytes: maxResponseBytes)
    }

    /// The response with its collected body.
    func response(for output: Output) -> HTTPClientResponse {
        HTTPClientResponse(
            status: output.status,
            headers: output.headers,
            body: .bytes(output.bytes() ?? ByteBuffer())
        )
    }
}
