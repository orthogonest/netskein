import AsyncHTTPClient
import Logging

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
}
