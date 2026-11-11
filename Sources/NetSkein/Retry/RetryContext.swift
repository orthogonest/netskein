import NIOHTTP1

/// What a ``RetryPolicy``'s evaluator knows when deciding whether to retry a failed attempt.
///
/// An attempt can end three ways:
///
/// - It received a response: ``responseStatus`` and ``responseHeaders`` are set, and ``error``
///   is `nil`.
/// - It failed before a response arrived, such as when the connection was refused: only
///   ``error`` is set.
/// - It received a response, then failed while reading the body, such as when the body was too
///   large: all three are set.
public struct RetryContext: Sendable {
    /// The retry being considered, starting at 1 for the first retry.
    public let attempt: Int
    /// The policy's ``RetryPolicy/maxRetries``.
    public let maxRetries: Int
    /// The request's method.
    public let method: HTTPMethod
    /// The request's URL.
    public let url: String
    /// The status of the attempt's response; `nil` when it failed before one arrived.
    public let responseStatus: HTTPResponseStatus?
    /// The headers of the attempt's response; `nil` when it failed before one arrived.
    public let responseHeaders: HTTPHeaders?
    /// The error the attempt failed with; `nil` when it succeeded.
    public let error: NetSkeinError?
}
