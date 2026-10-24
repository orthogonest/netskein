import NIOHTTP1
import Testing

@testable import NetSkein

struct HTTPMethodIdempotencyTests {
    @Test(
        "HTTPMethodIdempotencyTests: Verifies isIdempotent returns true only for RFC 9110 idempotent methods"
    )
    func testHTTPMethodIdempotency() {
        // Idempotent methods
        #expect(HTTPMethod.GET.isIdempotent == true)
        #expect(HTTPMethod.HEAD.isIdempotent == true)
        #expect(HTTPMethod.PUT.isIdempotent == true)
        #expect(HTTPMethod.DELETE.isIdempotent == true)
        #expect(HTTPMethod.OPTIONS.isIdempotent == true)
        #expect(HTTPMethod.TRACE.isIdempotent == true)

        // Non-idempotent methods
        #expect(HTTPMethod.POST.isIdempotent == false)
        #expect(HTTPMethod.PATCH.isIdempotent == false)
        #expect(HTTPMethod.CONNECT.isIdempotent == false)
        #expect(HTTPMethod.RAW(value: "CUSTOM").isIdempotent == false)
    }
}
