import Foundation
import Testing

@testable import NetSkein

struct NetSkeinURLEncoderTests {
    @Test(
        "NetSkeinURLEncoderTests: Verifies standard fields are correctly encoded and sorted alphabetically"
    )
    func testStandardEncodingAndSorting() {
        let fields = ["b_key": "value_b", "a_key": "value_a"]
        let result = NetSkeinURLEncoder().encode(fields)

        // Assert that sorting maintains deterministic predictable string matches
        #expect(result == "a_key=value_a&b_key=value_b")
    }

    @Test(
        "NetSkeinURLEncoderTests: Assures complex special characters matrices are successfully escaped according to W3C rules"
    )
    func testExtremeCharactersPercentEncoding() {
        let complexFields = [
            "email": "dev+test@netskein.io",
            "query": "name=john&age=30",
            "spaces": "hello world swift",
            "symbols": "id?/$#",
        ]

        let result = NetSkeinURLEncoder().encode(complexFields)

        // Assert specific token matches within the final output string layout
        #expect(result.contains("email=dev%2Btest%40netskein.io"))
        #expect(result.contains("query=name%3Djohn%26age%3D30"))
        // Verified W3C space-to-plus conversion
        #expect(result.contains("spaces=hello+world+swift"))
        #expect(result.contains("symbols=id%3F%2F%24%23"))
    }
}
