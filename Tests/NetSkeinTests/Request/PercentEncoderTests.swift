import Testing

@testable import NetSkein

struct PercentEncoderTests {
    @Test(
        "PercentEncoderTests: Verifies the shared default instance and basic path/form encoding"
    )
    func testBasicAndDefault() {
        let encoder = PercentEncoder.default
        #expect(encoder.encodePath("hello world") == "hello%20world")
        #expect(encoder.encodeForm(["key": "value"]) == "key=value")
    }

    @Test(
        "PercentEncoderTests: Verifies path and form encoding behaviors, sorting, and fallbacks"
    )
    func testEncodingAndFallback() {
        let encoder = PercentEncoder()
        #expect(encoder.encodePath("cross+path") == "cross%2Bpath")
        #expect(
            encoder.encodeForm(["b_key": "value_b", "a_key": "value_a"])
                == "a_key=value_a&b_key=value_b"
        )

        var fallbackEncoder = PercentEncoder()
        fallbackEncoder._percentEncode = { _, _ in nil }
        #expect(fallbackEncoder.encodePath("fallback segment") == "fallback segment")
        #expect(fallbackEncoder.encodeForm(["test Key": "test Value"]) == "test Key=test Value")
    }

    @Test(
        "PercentEncoderTests: Verifies standard fields are correctly encoded and sorted alphabetically"
    )
    func testStandardEncodingAndSorting() {
        let fields = ["b_key": "value_b", "a_key": "value_a"]
        let result = PercentEncoder().encodeForm(fields)

        // Assert that sorting maintains deterministic predictable string matches
        #expect(result == "a_key=value_a&b_key=value_b")
    }

    @Test(
        "PercentEncoderTests: Assures complex special characters matrices are successfully escaped according to W3C rules"
    )
    func testExtremeCharactersPercentEncoding() {
        let complexFields = [
            "email": "dev+test@netskein.io",
            "query": "name=john&age=30",
            "spaces": "hello world swift",
            "symbols": "id?/$#",
        ]

        let result = PercentEncoder().encodeForm(complexFields)

        // Assert specific token matches within the final output string layout
        #expect(result.contains("email=dev%2Btest%40netskein.io"))
        #expect(result.contains("query=name%3Djohn%26age%3D30"))
        // Verified W3C space-to-plus conversion
        #expect(result.contains("spaces=hello+world+swift"))
        #expect(result.contains("symbols=id%3F%2F%24%23"))
    }

    @Test(
        "PercentEncoderTests: Assures fallback execution when encountering malformed string characters"
    )
    func testMalformedCharactersFallback() {
        var encoder = PercentEncoder()
        encoder._percentEncode = { _, _ in nil }

        let result = encoder.encodeForm(["testKey": "test Value"])

        #expect(result == "testKey=test Value")
    }
}
