import Logging
import NIOCore
import Testing

@testable import NetSkein
@testable import NetSkeinTesting

struct MiddlewareContextTestingTests {
    @Test("MiddlewareContextTestingTests: Verifies the testing context uses first-attempt defaults")
    func testDefaults() {
        let context = MiddlewareContext.testing()

        #expect(context.attempt == 0)
        #expect(context.requestID == "test-request-id")
        #expect(context.logger.label == LoggerLabel.test)
        #expect(context.body == .none)
    }

    @Test("MiddlewareContextTestingTests: Verifies the testing context keeps the given values")
    func testCustomValues() {
        let context = MiddlewareContext.testing(
            attempt: 2,
            requestID: "custom",
            logger: Logger(label: "custom-logger"),
            body: .bytes(ByteBuffer(string: "payload"))
        )

        #expect(context.attempt == 2)
        #expect(context.requestID == "custom")
        #expect(context.logger.label == "custom-logger")
        #expect(context.body == .bytes(ByteBuffer(string: "payload")))
    }
}
