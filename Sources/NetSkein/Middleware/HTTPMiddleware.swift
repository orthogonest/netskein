import AsyncHTTPClient

/// A step in the request pipeline that can inspect or change each attempt's request and response.
///
/// By default, middleware runs once per attempt, inside the retry loop. Register it with
/// `per: .call` to run it once for the whole call instead, around every attempt. See
/// ``MiddlewareScope``. Middleware registered on the client wraps middleware registered on a
/// single request. Within each, the first one added runs first on the way out and last on the
/// way back.
///
/// Calling `next` sends the request to the rest of the chain. It may be called more than once,
/// for example to re-send after refreshing credentials: NetSkein attaches a fresh request body
/// on every call. Avoid reading the response body unless you replace it, so streaming responses
/// keep their constant memory use.
///
/// Errors thrown by `next` are always ``NetSkeinError``. Any other error thrown by a middleware
/// is reported as ``NetSkeinError/Kind/middlewareFailure``.
///
/// ```swift
/// struct AuthMiddleware: HTTPMiddleware {
///     let token: String
///
///     func intercept(
///         _ request: RequestHead,
///         context: MiddlewareContext,
///         next: Next
///     ) async throws -> HTTPClientResponse {
///         var request = request
///         request.headers.replaceOrAdd(name: "Authorization", value: "Bearer \(token)")
///         return try await next(request)
///     }
/// }
/// ```
public protocol HTTPMiddleware: Sendable {
    /// Sends a request to the rest of the chain and returns its response.
    typealias Next = @Sendable (RequestHead) async throws -> HTTPClientResponse

    /// Handles one request, usually by changing it, calling `next`, and returning the response.
    ///
    /// - Parameters:
    ///   - request: The request as left by the middleware before this one.
    ///   - context: The attempt number, request ID, logger and body.
    ///   - next: Sends a request to the rest of the chain.
    /// - Returns: The response to hand back to the middleware before this one.
    /// - Throws: Any error. Errors that aren't a ``NetSkeinError`` are reported as
    ///   ``NetSkeinError/Kind/middlewareFailure``.
    func intercept(
        _ request: RequestHead,
        context: MiddlewareContext,
        next: Next
    ) async throws -> HTTPClientResponse
}
