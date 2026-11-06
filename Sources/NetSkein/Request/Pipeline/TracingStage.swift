import NIOHTTP1
import Tracing

/// The outermost stage: runs one call, including all of its retry attempts, inside a span, so
/// the transport's per-attempt spans are grouped under it and the span covers backoff and body
/// transfer.
struct TracingStage: Sendable {
    /// `nil` runs the call without a span.
    let tracer: (any Tracer)?
    let method: HTTPMethod

    func run<Success>(
        _ operation: String,
        requestID: String,
        _ body: ((any Span)?) async throws(NetSkeinError) -> Success
    ) async throws(NetSkeinError) -> Success {
        guard let tracer else { return try await body(nil) }

        let span = tracer.startSpan("NetSkein \(method.rawValue)", ofKind: .internal)
        defer { span.end() }
        span.attributes["http.request.method"] = method.rawValue
        span.attributes["netskein.operation"] = operation
        span.attributes["netskein.request_id"] = requestID

        // Make the span current, so the transport's spans become its children
        let result = await ServiceContext.$current.withValue(span.context) {
            await Result { () async throws(NetSkeinError) in try await body(span) }
        }
        if case let .failure(error) = result {
            span.recordError(error)
            span.setStatus(SpanStatus(code: .error))
        }
        return try result.get()
    }
}
