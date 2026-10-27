import AsyncHTTPClient

enum MiddlewareChain {
    /// Sends `head` through `middlewares` in order, ending at `transport`.
    ///
    /// `transport` must only throw ``NetSkeinError``; that is what lets errors coming out of a
    /// middleware be told apart from errors it merely passed along from `next`.
    static func run(
        _ head: RequestHead,
        through middlewares: [any HTTPMiddleware],
        context: MiddlewareContext,
        transport: @escaping HTTPMiddleware.Next
    ) async throws -> HTTPClientResponse {
        let chain = middlewares.reversed()
            .reduce(transport) { next, middleware in
                wrap(middleware, context: context, next: next)
            }
        return try await chain(head)
    }

    private static func wrap(
        _ middleware: any HTTPMiddleware,
        context: MiddlewareContext,
        next: @escaping HTTPMiddleware.Next
    ) -> HTTPMiddleware.Next {
        { head in
            do {
                return try await middleware.intercept(head, context: context, next: next)
            } catch let error as NetSkeinError {
                throw error
            } catch {
                // `next` only throws NetSkeinError, so anything else came from the middleware
                // itself; keep it distinct from network failures so it is not retried as one
                throw NetSkeinError.custom(
                    kind: .middlewareFailure,
                    message: "\(type(of: middleware)) failed: \(error.localizedDescription)",
                    underlyingError: error
                )
            }
        }
    }
}
