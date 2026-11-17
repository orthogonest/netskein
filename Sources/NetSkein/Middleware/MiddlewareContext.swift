import Logging

/// Read-only information about the attempt a middleware is handling.
public struct MiddlewareContext: Sendable {
    /// The 0-based attempt number. Greater than 0 when the request is being retried.
    public let attempt: Int
    /// The value sent in the `X-Request-ID` header. The same for every attempt of a request.
    public let requestID: String
    /// A logger already tagged with this attempt's request metadata.
    public let logger: Logger
    /// The request body that NetSkein attaches each time `next` is called.
    public let body: RequestBodyDescription

    /// Creates a context, such as for testing a middleware on its own.
    ///
    /// - Parameters:
    ///   - attempt: The 0-based attempt number.
    ///   - requestID: The value sent in the `X-Request-ID` header.
    ///   - logger: The logger the middleware writes to.
    ///   - body: The request body.
    public init(attempt: Int, requestID: String, logger: Logger, body: RequestBodyDescription) {
        self.attempt = attempt
        self.requestID = requestID
        self.logger = logger
        self.body = body
    }
}
