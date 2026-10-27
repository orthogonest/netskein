import AsyncHTTPClient

/// Adapts a closure to ``HTTPMiddleware`` for the closure form of `using(_:)`.
package struct ClosureMiddleware {
    package typealias Intercept =
        @Sendable (
            RequestHead,
            MiddlewareContext,
            Next
        ) async throws -> HTTPClientResponse

    private let handler: Intercept

    package init(_ handler: @escaping Intercept) {
        self.handler = handler
    }
}

extension ClosureMiddleware: HTTPMiddleware {
    package func intercept(
        _ request: RequestHead,
        context: MiddlewareContext,
        next: Next
    ) async throws -> HTTPClientResponse {
        try await handler(request, context, next)
    }
}
