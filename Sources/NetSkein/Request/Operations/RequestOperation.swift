import AsyncHTTPClient
import Logging
import NIOHTTP1

/// What one kind of call does with each attempt's response. The pipeline stages do everything
/// else: building the request, middleware, transport, retries, backoff and tracing.
protocol RequestOperation: Sendable {
    associatedtype Output: Sendable

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

    /// The call's result as a response, for middleware that runs once per call
    /// (``MiddlewareScope/call``).
    func response(for output: Output) -> HTTPClientResponse
}

/// What an operation needs for one attempt: how it is logged, and any headers it adds.
struct AttemptSetup {
    /// Names the attempt in logs, after "Initiating" or "Retrying", such as `file download`.
    var description: String
    /// Added to the request for this attempt only, such as `Range` when resuming a download.
    var extraHeaders: HTTPHeaders = [:]
    /// Logged as a warning when the attempt starts, for a risk the caller should know about.
    var warning: String?
}
