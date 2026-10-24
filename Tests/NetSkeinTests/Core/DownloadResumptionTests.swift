import Foundation
import Testing

@testable import NetSkein

struct DownloadResumptionTests {
    @Test("DownloadResumptionTests: Verifies equality and inequality across all enum cases")
    func testEquality() {
        // Same cases equality
        #expect(DownloadResumption.disabled == DownloadResumption.disabled)
        #expect(DownloadResumption.onRetry == DownloadResumption.onRetry)
        #expect(DownloadResumption.ifPossible() == DownloadResumption.ifPossible(validator: nil))
        #expect(
            DownloadResumption.ifPossible(validator: "etag-123")
                == DownloadResumption.ifPossible(validator: "etag-123")
        )

        // Different cases inequality
        #expect(DownloadResumption.disabled != DownloadResumption.onRetry)
        #expect(DownloadResumption.disabled != DownloadResumption.ifPossible())
        #expect(DownloadResumption.onRetry != DownloadResumption.ifPossible())
        #expect(
            DownloadResumption.ifPossible(validator: "etag-123")
                != DownloadResumption.ifPossible(validator: "etag-456")
        )
        #expect(
            DownloadResumption.ifPossible(validator: "etag-123")
                != DownloadResumption.ifPossible(validator: nil)
        )
    }

    @Test("DownloadResumptionTests: Verifies validator returns correct value or nil for each case")
    func testValidatorProperty() {
        // Disabled returns nil
        let disabledStrategy = DownloadResumption.disabled
        #expect(disabledStrategy.validator == nil)

        // onRetry returns nil
        let onRetryStrategy = DownloadResumption.onRetry
        #expect(onRetryStrategy.validator == nil)

        // ifPossible without validator returns nil
        let ifPossibleNil = DownloadResumption.ifPossible()
        #expect(ifPossibleNil.validator == nil)

        // ifPossible with validator returns the exact validator string
        let ifPossibleWithETag = DownloadResumption.ifPossible(validator: "\"3f8a-5b128e9b\"")
        #expect(ifPossibleWithETag.validator == "\"3f8a-5b128e9b\"")

        let ifPossibleWithDate = DownloadResumption.ifPossible(
            validator: "Wed, 21 Oct 2026 07:28:00 GMT"
        )
        #expect(ifPossibleWithDate.validator == "Wed, 21 Oct 2026 07:28:00 GMT")
    }

    @Test("DownloadResumptionTests: Verifies ContentRangeParser extracts valid total byte lengths")
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
        "DownloadResumptionTests: Verifies ContentRangeParser returns nil for malformed or missing headers"
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
