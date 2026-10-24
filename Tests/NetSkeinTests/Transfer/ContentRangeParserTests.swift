import Foundation
import Testing

@testable import NetSkein

struct ContentRangeParserTests {
    @Test("ContentRangeParserTests: Verifies ContentRangeParser extracts valid total byte lengths")
    func testContentRangeParserValidHeaders() {
        // Standard range response: "bytes 200-1000/67589"
        let standardHeader = "bytes 200-1000/67589"
        #expect(ContentRangeParser.parseTotalBytes(from: standardHeader) == 67589)

        // Unsatisfied range format (RFC 9110): "bytes */5000"
        let unsatisfiedHeader = "bytes */5000"
        #expect(ContentRangeParser.parseTotalBytes(from: unsatisfiedHeader) == 5000)

        // Range starting from 0: "bytes 0-499/1234"
        let startHeader = "bytes 0-499/1234"
        #expect(ContentRangeParser.parseTotalBytes(from: startHeader) == 1234)

        // Whitespace padding after slash: "bytes 0-10/ 42000 "
        let paddedHeader = "bytes 0-10/ 42000 "
        #expect(ContentRangeParser.parseTotalBytes(from: paddedHeader) == 42000)

        // Max Int64 boundary
        let maxInt64String = String(Int64.max)
        let largeHeader = "bytes 0-10/\(maxInt64String)"
        #expect(ContentRangeParser.parseTotalBytes(from: largeHeader) == Int64.max)
    }

    @Test(
        "ContentRangeParserTests: Verifies ContentRangeParser returns nil for malformed or missing headers"
    )
    func testContentRangeParserInvalidHeaders() {
        // Nil header
        #expect(ContentRangeParser.parseTotalBytes(from: nil) == nil)

        // Empty string
        #expect(ContentRangeParser.parseTotalBytes(from: "") == nil)

        // Missing slash
        #expect(ContentRangeParser.parseTotalBytes(from: "bytes 200-1000") == nil)
        #expect(ContentRangeParser.parseTotalBytes(from: "67589") == nil)

        // Unknown total size represented by '*' (RFC 9110 §14.4)
        #expect(ContentRangeParser.parseTotalBytes(from: "bytes 200-1000/*") == nil)

        // Empty string after slash
        #expect(ContentRangeParser.parseTotalBytes(from: "bytes 200-1000/") == nil)
        #expect(ContentRangeParser.parseTotalBytes(from: "bytes 200-1000/   ") == nil)

        // Non-numeric text after slash
        #expect(ContentRangeParser.parseTotalBytes(from: "bytes 200-1000/unknown") == nil)
        #expect(ContentRangeParser.parseTotalBytes(from: "bytes 200-1000/123a") == nil)

        // Numeric overflow beyond Int64.max
        #expect(
            ContentRangeParser.parseTotalBytes(from: "bytes 0-10/999999999999999999999999999999")
                == nil
        )
    }
}
