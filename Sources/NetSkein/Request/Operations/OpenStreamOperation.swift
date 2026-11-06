import AsyncHTTPClient
import Logging
import NIOHTTP1

/// Returns a successful response with its body unread, for the caller to pull from.
struct OpenStreamOperation: RequestOperation {
    typealias Output = HTTPClientResponse

    var name: String { "stream" }
    var action: String { "Streaming request" }
    var isBuffered: Bool { false }
    var hasDeliveredData: Bool { false }

    func prepareAttempt() -> AttemptSetup {
        AttemptSetup(description: "outbound streaming request")
    }

    func handle(_ response: HTTPClientResponse, logger: Logger) async throws -> Output {
        guard response.status.code >= 200 && response.status.code < 300 else {
            throw NetSkeinError.badStatus(response.status)
        }
        return response
    }

    /// The response itself, with its body still to be read by the caller.
    func response(for output: Output) -> HTTPClientResponse {
        output
    }
}
