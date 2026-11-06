import AsyncHTTPClient

/// Applies a ``CircuitBreaker`` to every attempt. The client places it next to the transport,
/// inside the cache, so cached responses stay available while a circuit is open.
struct CircuitBreakerMiddleware: HTTPMiddleware {
    let breaker: CircuitBreaker

    func intercept(
        _ request: RequestHead,
        context: MiddlewareContext,
        next: Next
    ) async throws -> HTTPClientResponse {
        let permit = try breaker.acquire(breaker.key(request), logger: context.logger)
        do {
            let response = try await next(request)
            breaker.record(.success(response.status), for: permit, logger: context.logger)
            return response
        } catch {
            if Task.isCancelled {
                breaker.release(permit)
            } else {
                let failure = context.netSkeinError(from: error, action: "Circuit breaker")
                breaker.record(.failure(failure), for: permit, logger: context.logger)
            }
            throw error
        }
    }
}
