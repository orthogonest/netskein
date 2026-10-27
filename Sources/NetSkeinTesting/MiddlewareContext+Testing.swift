import Logging
import NetSkein

extension MiddlewareContext {
    /// A context for calling ``HTTPMiddleware/intercept(_:context:next:)`` directly in unit tests.
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
