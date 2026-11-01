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

    @Test(
        "DownloadResumptionTests: Verifies ifRangeValidator returns the caller's strong validator or nil"
    )
    func testValidatorProperty() {
        // Disabled returns nil
        let disabledStrategy = DownloadResumption.disabled
        #expect(disabledStrategy.ifRangeValidator == nil)

        // onRetry returns nil
        let onRetryStrategy = DownloadResumption.onRetry
        #expect(onRetryStrategy.ifRangeValidator == nil)

        // ifPossible without validator returns nil
        let ifPossibleNil = DownloadResumption.ifPossible()
        #expect(ifPossibleNil.ifRangeValidator == nil)

        // ifPossible with validator returns the exact validator string
        let ifPossibleWithETag = DownloadResumption.ifPossible(validator: "\"3f8a-5b128e9b\"")
        #expect(ifPossibleWithETag.ifRangeValidator == "\"3f8a-5b128e9b\"")

        let ifPossibleWithDate = DownloadResumption.ifPossible(
            validator: "Wed, 21 Oct 2026 07:28:00 GMT"
        )
        #expect(ifPossibleWithDate.ifRangeValidator == "Wed, 21 Oct 2026 07:28:00 GMT")

        // A weak ETag cannot be used in If-Range
        #expect(DownloadResumption.ifPossible(validator: "W/\"3f8a\"").ifRangeValidator == nil)
    }
}
