import AsyncHTTPClient
import Logging
import NIOHTTP1

/// What one kind of call does with each attempt's response. The pipeline stages do everything
/// else: building the request, middleware, transport, retries, backoff and tracing.
protocol RequestOperation {
    associatedtype Output

    /// Names the call in spans, for example `send`.
    var name: String { get }

    /// Names the call in error logs and error messages, for example `Network request`.
    var action: String { get }

    /// Whether the whole response is collected before the caller sees any of it.
    ///
    /// Only a buffered call can retry after its response was handled: nothing has reached
    /// the caller yet, so the response can simply be thrown away.
    var isBuffered: Bool { get }

    /// Whether the caller has already received part of a response.
    ///
    /// A failure after that is never retried: the next attempt would start the response from
    /// the beginning and hand the caller the same data twice.
    var hasDeliveredData: Bool { get }

    /// Runs before every attempt: describes it in logs and adds any headers it needs.
    mutating func prepareAttempt() -> AttemptSetup

    /// Turns an attempt's response into the call's result. Throwing counts as a failed attempt.
    mutating func handle(_ response: HTTPClientResponse, logger: Logger) async throws -> Output
}

/// How one attempt is described in logs, and any headers it adds to the request.
struct AttemptSetup {
    var description: String
    var extraHeaders: HTTPHeaders = [:]
}
