import AsyncHTTPClient
import Foundation
import NIOHTTP1
import Testing

@testable import NetSkein

struct NetSkeinErrorTests {
    @Test(
        "NetSkeinErrorTests: Verifies simple factory accurately retains kind properties and triggers default localizations"
    )
    func testSimpleErrorLayout() {
        let error = NetSkeinError.simple(.networkFailure)

        #expect(error.kind == .networkFailure)
        #expect(error.errorDescription == "A network connectivity or timeout error occurred.")
        #expect(error.failureReason?.contains("DNS resolution failure") == true)
    }

    @Test(
        "NetSkeinErrorTests: Verifies custom factory injects specialized descriptions and unpacks localized underlying reasons"
    )
    func testCustomErrorLayout() {
        let underlying = MockUnderlyingError()
        let error = NetSkeinError.custom(
            kind: .invalidPayload,
            message: "Custom parsing payload malfunction.",
            underlyingError: underlying
        )

        #expect(error.kind == .invalidPayload)
        #expect(error.errorDescription == "Custom parsing payload malfunction.")
        #expect(error.failureReason == "Root cause of failure.")
    }

    @Test(
        "NetSkeinErrorTests: Verifies badStatus correctly maps client codes to clientError kinds with customized structural messages"
    )
    func testBadStatusClientErrorMapping() {
        // HTTP 404 Not Found -> Client side error
        let status = HTTPResponseStatus.notFound
        let error = NetSkeinError.badStatus(status)

        #expect(error.kind == .clientError)
        #expect(
            error.errorDescription
                == "The server returned an unexpected status code: 404 (Not Found)."
        )
    }

    @Test(
        "NetSkeinErrorTests: Verifies badStatus correctly maps server error codes to serverError kinds with customized structural messages"
    )
    func testBadStatusServerErrorMapping() {
        // HTTP 503 Service Unavailable -> Server side error
        let status = HTTPResponseStatus.serviceUnavailable
        let error = NetSkeinError.badStatus(status)

        #expect(error.kind == .serverError)
        #expect(
            error.errorDescription
                == "The server returned an unexpected status code: 503 (Service Unavailable)."
        )
    }

    @Test(
        "NetSkeinErrorTests: Assures structural equatable operator correctly compares error pairs based on internal layout representations"
    )
    func testEquatableLogic() {
        let simpleNetwork1 = NetSkeinError.simple(.networkFailure)
        let simpleNetwork2 = NetSkeinError.simple(.networkFailure)
        let simpleIO = NetSkeinError.simple(.ioFailure)

        let customPayload1 = NetSkeinError.custom(kind: .invalidPayload, message: "Error Alpha")
        let customPayload2 = NetSkeinError.custom(kind: .invalidPayload, message: "Error Alpha")
        let customPayloadDifferentMsg = NetSkeinError.custom(
            kind: .invalidPayload,
            message: "Error Beta"
        )

        // Equatable assertions
        #expect(simpleNetwork1 == simpleNetwork2)
        #expect(simpleNetwork1 != simpleIO)
        #expect(customPayload1 == customPayload2)
        #expect(customPayload1 != customPayloadDifferentMsg)
        #expect(simpleNetwork1 != customPayload1)
    }

    @Test(
        "NetSkeinErrorTests: Ensures distinct error objects distribute unique hash values safely across structures"
    )
    func testHashableLogic() {
        let error1 = NetSkeinError.simple(.networkFailure)
        let error2 = NetSkeinError.simple(.networkFailure)
        let error3 = NetSkeinError.custom(kind: .networkFailure, message: "Unique Context Log")

        var hasher1 = Hasher()
        var hasher2 = Hasher()
        var hasher3 = Hasher()

        error1.hash(into: &hasher1)
        error2.hash(into: &hasher2)
        error3.hash(into: &hasher3)

        #expect(hasher1.finalize() == hasher2.finalize())
        #expect(hasher1.finalize() != hasher3.finalize())
    }

    @Test(
        "NetSkeinErrorTests: Verifies remaining simple enum kinds fallback cleanly to designated default descriptions"
    )
    func testRemainingSimpleLocalizations() {
        let payloadErr = NetSkeinError.simple(.invalidPayload)
        #expect(payloadErr.errorDescription?.contains("response payload data") == true)
        #expect(payloadErr.failureReason?.contains("The client data") == true)

        let clientErr = NetSkeinError.simple(.clientError)
        #expect(clientErr.errorDescription?.contains("client-side error") == true)
        #expect(clientErr.failureReason?.contains("The server rejected the request") == true)

        let serverErr = NetSkeinError.simple(.serverError)
        #expect(
            serverErr.errorDescription?.contains("The server encountered an internal error") == true
        )
        #expect(
            serverErr.failureReason?.contains("The upstream server is currently unavailable")
                == true
        )

        let emptyBody = NetSkeinError.simple(.emptyResponseBody)
        #expect(
            emptyBody.errorDescription?.contains("the response body was unexpectedly empty.")
                == true
        )
        #expect(emptyBody.failureReason?.contains("zero readable bytes.") == true)

        let ioFail = NetSkeinError.simple(.ioFailure)
        #expect(ioFail.errorDescription?.contains("input/output error occurred.") == true)
        #expect(ioFail.failureReason?.contains("secure file handle") == true)
    }
}

// MARK: - Middleware Failure

extension NetSkeinErrorTests {
    @Test("NetSkeinErrorTests: Verifies middlewareFailure has its own default descriptions")
    func testMiddlewareFailureLocalization() {
        let error = NetSkeinError.simple(.middlewareFailure)

        #expect(error.errorDescription == "A middleware failed while handling the request.")
        #expect(error.failureReason?.contains("A registered middleware threw an error") == true)
    }
}

struct MockUnderlyingError: Error, LocalizedError, Sendable {
    var errorDescription: String? { "Root cause of failure." }
}
