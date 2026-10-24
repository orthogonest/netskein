import Foundation
import NIOCore
import NIOHTTP1
import Testing

@testable import NetSkein

struct RetryAfterParserTests {
    @Test("RetryAfterParserTests: Verifies parsing delta-seconds format")
    func testRetryAfterSeconds() {
        var headers = HTTPHeaders()
        headers.add(name: "Retry-After", value: "120")
        #expect(RetryAfterParser.parseDelay(from: headers) == .seconds(120))

        headers.replaceOrAdd(name: "Retry-After", value: "0")
        #expect(RetryAfterParser.parseDelay(from: headers) == .seconds(0))
    }

    @Test("RetryAfterParserTests: Verifies parsing HTTP-Date format for future and past dates")
    func testRetryAfterHTTPDate() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        // 1. Future date (+60 seconds)
        let futureDate = Date().addingTimeInterval(60)
        var headers = HTTPHeaders()
        headers.add(name: "Retry-After", value: formatter.string(from: futureDate))

        let parsedDelay = RetryAfterParser.parseDelay(from: headers)
        #expect(parsedDelay != nil)
        #expect((parsedDelay?.nanoseconds ?? 0) > 0)
        #expect((parsedDelay?.nanoseconds ?? 0) <= TimeAmount.seconds(65).nanoseconds)

        // 2. Past date (-60 seconds) -> Clamped to 0
        let pastDate = Date().addingTimeInterval(-60)
        headers.replaceOrAdd(name: "Retry-After", value: formatter.string(from: pastDate))
        #expect(RetryAfterParser.parseDelay(from: headers) == .nanoseconds(0))
    }

    @Test("RetryAfterParserTests: Verifies returns nil for missing, negative, or malformed headers")
    func testRetryAfterInvalidHeaders() {
        // Missing header
        #expect(RetryAfterParser.parseDelay(from: nil) == nil)
        #expect(RetryAfterParser.parseDelay(from: HTTPHeaders()) == nil)

        // Negative integer
        var headers = HTTPHeaders()
        headers.add(name: "Retry-After", value: "-10")
        #expect(RetryAfterParser.parseDelay(from: headers) == nil)

        // Malformed non-numeric text
        headers.replaceOrAdd(name: "Retry-After", value: "invalid-value")
        #expect(RetryAfterParser.parseDelay(from: headers) == nil)
    }
}
