import NIOHTTP1
import Testing

@testable import NetSkein

struct HTTPValidatorTests {
    let date = "Sat, 31 Oct 2026 10:00:00 GMT"
    let oneSecondEarlier = "Sat, 31 Oct 2026 09:59:59 GMT"
}

// MARK: - Conditional Requests

extension HTTPValidatorTests {
    @Test("HTTPValidatorTests: RFC 9110 §13.1 sends every validator back as a condition")
    func testConditionalHeaders() {
        let both = HTTPValidator(["ETag": "W/\"v1\"", "Last-Modified": date])
        #expect(both.conditionalHeaders.first(name: "If-None-Match") == "W/\"v1\"")
        #expect(both.conditionalHeaders.first(name: "If-Modified-Since") == date)

        #expect(HTTPValidator([:]).conditionalHeaders.isEmpty)
    }
}

// MARK: - If-Range

extension HTTPValidatorTests {
    @Test("HTTPValidatorTests: RFC 9110 §13.1.5 If-Range prefers a strong ETag")
    func testIfRangeStrongEntityTag() {
        let validator = HTTPValidator([
            "ETag": "\"v1\"", "Last-Modified": oneSecondEarlier, "Date": date,
        ])

        #expect(validator.ifRange == "\"v1\"")
    }

    @Test(
        "HTTPValidatorTests: RFC 9110 §8.8.2.2 If-Range falls back to a Last-Modified one second before Date"
    )
    func testIfRangeLastModified() {
        let validator = HTTPValidator([
            "ETag": "W/\"v1\"", "Last-Modified": oneSecondEarlier, "Date": date,
        ])

        #expect(validator.ifRange == oneSecondEarlier)
    }

    @Test(
        "HTTPValidatorTests: RFC 9110 §13.1.5 If-Range is never weak",
        arguments: [
            HTTPHeaders([("ETag", "W/\"v1\"")]),
            HTTPHeaders([("Last-Modified", "Sat, 31 Oct 2026 10:00:00 GMT")]),
            HTTPHeaders([
                ("Last-Modified", "Sat, 31 Oct 2026 10:00:00 GMT"),
                ("Date", "Sat, 31 Oct 2026 10:00:00 GMT"),
            ]),
            HTTPHeaders([
                ("Last-Modified", "not a date"), ("Date", "Sat, 31 Oct 2026 10:00:00 GMT"),
            ]),
            HTTPHeaders(),
        ]
    )
    func testIfRangeWeak(headers: HTTPHeaders) {
        #expect(HTTPValidator(headers).ifRange == nil)
    }
}

// MARK: - Matching

extension HTTPValidatorTests {
    @Test("HTTPValidatorTests: RFC 9110 §8.8.3.2 entity tags match by weak comparison")
    func testMatchesEntityTag() {
        let stored = HTTPValidator(["ETag": "\"v1\""])

        #expect(stored.matches(HTTPValidator(["ETag": "W/\"v1\""])))
        #expect(!stored.matches(HTTPValidator(["ETag": "\"v2\""])))
        #expect(!HTTPValidator([:]).matches(HTTPValidator(["ETag": "\"v1\""])))
    }

    @Test("HTTPValidatorTests: RFC 9111 §4.3.4 without an ETag, Last-Modified must be equal")
    func testMatchesLastModified() {
        let stored = HTTPValidator(["Last-Modified": date])

        #expect(stored.matches(HTTPValidator(["Last-Modified": date])))
        #expect(!stored.matches(HTTPValidator(["Last-Modified": oneSecondEarlier])))
        #expect(stored.matches(HTTPValidator([:])))
    }
}
