import AsyncHTTPClient

/// A step in the request pipeline that can inspect or change each attempt's request and response.
///
/// Middleware runs once per attempt, inside the retry loop. Middleware registered on the client
/// wraps middleware registered on a single request; within each, the first one added runs first
/// on the way out and last on the way back.
///
/// Calling `next` sends the request to the rest of the chain. It may be called more than once,
/// for example to re-send after refreshing credentials: NetSkein attaches a fresh request body
/// on every call. Avoid reading the response body unless you replace it, so streaming responses
/// keep their constant memory use.
///
/// Errors thrown by `next` are always ``NetSkeinError``. Any other error thrown by a middleware
/// is reported as ``NetSkeinError/Kind/middlewareFailure``.
public protocol HTTPMiddleware: Sendable {
    typealias Next = @Sendable (RequestHead) async throws -> HTTPClientResponse

    func intercept(
        _ request: RequestHead,
        context: MiddlewareContext,
        next: Next
    ) async throws -> HTTPClientResponse
}
