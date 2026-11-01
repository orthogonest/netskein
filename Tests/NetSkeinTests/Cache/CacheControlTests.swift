import Foundation
import NIOCore
import NIOHTTP1
import Testing

@testable import NetSkein

struct CacheControlTests {}

// MARK: - Cache-Control

extension CacheControlTests {
    @Test("CacheControlTests: §5.2 reads directives from every field, case-insensitively")
    func testReadsAllFields() {
        let headers: HTTPHeaders = [
            "Cache-Control": "Max-Age=60, NO-CACHE",
            "cache-control": "private",
        ]
        let cacheControl = CacheControl(headers)

        #expect(cacheControl.seconds("max-age") == 60)
        #expect(cacheControl.contains("no-cache"))
        #expect(cacheControl.contains("private"))
        #expect(!cacheControl.contains("no-store"))
    }

    @Test("CacheControlTests: §4.2.1 the first occurrence of a directive wins")
    func testFirstOccurrenceWins() {
        let cacheControl = CacheControl(["Cache-Control": "max-age=10, max-age=99"])

        #expect(cacheControl.seconds("max-age") == 10)
    }

    @Test("CacheControlTests: §1.2.2 invalid delta-seconds count as 0 and large ones are capped")
    func testDeltaSeconds() {
        let cacheControl = CacheControl([
            "Cache-Control": "max-age=abc, min-fresh=, s-maxage=99999999999999999999, max-stale"
        ])

        #expect(cacheControl.seconds("max-age") == 0)
        #expect(cacheControl.seconds("min-fresh") == 0)
        #expect(cacheControl.seconds("s-maxage") == CacheControl.maxDeltaSeconds)
        #expect(cacheControl.seconds("max-stale") == 0)
        #expect(cacheControl.seconds("missing") == nil)
    }

    @Test("CacheControlTests: tells directives with and without an argument apart")
    func testHasArgument() {
        let cacheControl = CacheControl(["Cache-Control": "max-stale, max-age=5"])

        #expect(!cacheControl.hasArgument("max-stale"))
        #expect(cacheControl.hasArgument("max-age"))
        #expect(!cacheControl.hasArgument("missing"))
    }

    @Test("CacheControlTests: §5.2 commas inside quoted values do not split directives")
    func testQuotedCommas() {
        let cacheControl = CacheControl([
            "Cache-Control": #"no-cache="Set-Cookie, X-Secret", private, , max-age=1"#
        ])

        #expect(cacheControl.contains("no-cache"))
        #expect(cacheControl.contains("private"))
        #expect(!cacheControl.contains("x-secret\""))
        #expect(cacheControl.seconds("max-age") == 1)
    }

    @Test("CacheControlTests: keeps a lone quote character as a value")
    func testLoneQuote() {
        let cacheControl = CacheControl(["Cache-Control": #"ext=""#])

        #expect(cacheControl.hasArgument("ext"))
    }
}
