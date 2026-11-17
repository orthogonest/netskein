import Logging
import NetSkein

extension MiddlewareContext {
    /// A context for calling `HTTPMiddleware.intercept(_:context:next:)` directly in unit tests.
    ///
    /// ```swift
    /// let response = try await AuthMiddleware(token: "secret").intercept(
    ///     RequestHead(method: .GET, url: "https://api.example.com/me", headers: [:]),
    ///     context: .testing(),
    ///     next: { request in
    ///         #expect(request.headers.first(name: "Authorization") == "Bearer secret")
    ///         return HTTPClientResponse(status: .ok)
    ///     }
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - attempt: The attempt number, starting at 0 (default: 0).
    ///   - requestID: The request ID (default: `test-request-id`).
    ///   - logger: The logger (default: `nil`, a logger labeled `com.netskein.test`).
    ///   - body: The request body (default: `.none`).
    /// - Returns: The context.
    public static func testing(
        attempt: Int = 0,
        requestID: String = "test-request-id",
        logger: Logger? = nil,
        body: RequestBodyDescription = .none
    ) -> MiddlewareContext {
        MiddlewareContext(
            attempt: attempt,
            requestID: requestID,
            logger: logger ?? Logger(label: LoggerLabel.test),
            body: body
        )
    }
}
