import AsyncHTTPClient
import NIOConcurrencyHelpers

/// Runs the middleware registered per call (``MiddlewareScope/call``) once, around the retry
/// stage and every attempt it makes.
///
/// `next` runs the rest of the call with the request the middleware passes it, and returns the
/// call's result as a response (``RequestOperation/response(for:)``). The call ends with the
/// result of the last `next` that succeeded. When none did, because the middleware answered
/// without `next` or recovered from its error, the operation handles the response the
/// middleware returned instead.
struct CallStage: Sendable {
    let middlewares: [any HTTPMiddleware]
    let context: MiddlewareContext

    /// The operation as left by the latest run of `rest`, and that run's output when it succeeded.
    private struct State<Operation: RequestOperation>: Sendable {
        var operation: Operation
        var output: Operation.Output?
    }

    func run<Operation: RequestOperation>(
        _ head: RequestHead,
        operation: Operation,
        rest:
            @escaping @Sendable (
                RequestHead,
                inout Operation
            ) async throws(NetSkeinError) -> Operation.Output
    ) async throws(NetSkeinError) -> Operation.Output {
        var operation = operation
        let action = operation.action
        guard !middlewares.isEmpty else { return try await rest(head, &operation) }

        let state = NIOLockedValueBox(State(operation: operation, output: nil))
        do {
            let response = try await MiddlewareChain.run(
                head,
                through: middlewares,
                context: context
            ) { head in
                var operation = state.withLockedValue { $0.operation }
                do {
                    let output = try await rest(head, &operation)
                    state.withLockedValue {
                        $0.operation = operation
                        $0.output = output
                    }
                    return operation.response(for: output)
                } catch {
                    state.withLockedValue { $0.operation = operation }
                    throw error
                }
            }

            let finished = state.withLockedValue { $0 }
            if let output = finished.output { return output }

            operation = finished.operation
            return try await operation.handle(response, logger: context.logger)
        } catch {
            throw context.netSkeinError(from: error, action: action)
        }
    }
}
