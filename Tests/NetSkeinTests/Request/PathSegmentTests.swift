import Foundation
import Testing

@testable import NetSkein

struct PathSegmentTests {
    @Test("PathSegmentTests: Verifies initialization from a plain string literal")
    func testStringLiteralInitialization() {
        let segment: PathSegment = "users/profile"

        #expect(segment.value == "users/profile")
    }

    @Test("PathSegmentTests: Verifies integer interpolation formats correctly")
    func testIntInterpolation() {
        let userId = 42
        let segment: PathSegment = "users/\(userId)/details"

        #expect(segment.value == "users/42/details")
    }

    @Test(
        "PathSegmentTests: Verifies string interpolation applies URL path encoding automatically"
    )
    func testStringInterpolationWithEncoding() {
        let nameWithSpaces = "john doe"
        let specialChars = "hello/world"

        let segment1: PathSegment = "search/\(nameWithSpaces)"
        let segment2: PathSegment = "tags/\(specialChars)"

        #expect(segment1.value == "search/john%20doe")
        #expect(segment2.value == "tags/hello%2Fworld")
    }

    @Test(
        "PathSegmentTests: Verifies UUID interpolation formats cleanly as standard string"
    )
    func testUUIDInterpolation() {
        let uuid = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
        let segment: PathSegment = "devices/\(uuid)"

        #expect(segment.value == "devices/E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
    }

    @Test(
        "PathSegmentTests: Verifies mixed interpolation types compile and resolve in correct sequential order"
    )
    func testMixedInterpolation() {
        let category = "mobile apps"
        let version = 6
        let sessionId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let segment: PathSegment =
            "archive/\(category)/swift\(version)/session-\(sessionId)"

        let expected = "archive/mobile%20apps/swift6/session-11111111-2222-3333-4444-555555555555"
        #expect(segment.value == expected)
    }
}
