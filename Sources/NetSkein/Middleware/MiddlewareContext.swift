import Logging

/// Read-only information about the attempt a middleware is handling.
public struct MiddlewareContext: Sendable {
    /// The 0-based attempt number; greater than 0 when the request is being retried.
    public let attempt: Int
    /// The value sent in the `X-Request-ID` header for this attempt.
    public let requestID: String
    /// A logger already tagged with this attempt's request metadata.
    public let logger: Logger
    /// The request body that NetSkein attaches each time `next` is called.
    public let body: RequestBodyDescription

    public init(attempt: Int, requestID: String, logger: Logger, body: RequestBodyDescription) {
        self.attempt = attempt
        self.requestID = requestID
        self.logger = logger
        self.body = body
    }
}
