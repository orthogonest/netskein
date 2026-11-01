import Foundation
import NIOHTTP1
import Testing

@testable import NetSkein

struct HTTPDateTests {
    @Test("HTTPDateTests: RFC 9110 §5.6.7 parses the three HTTP date formats")
    func testFormats() {
        let expected = Date(timeIntervalSince1970: 784_111_777)

        #expect(HTTPDate.parse("Sun, 06 Nov 1994 08:49:37 GMT") == expected)
        #expect(HTTPDate.parse("Sunday, 06-Nov-94 08:49:37 GMT") == expected)
        #expect(HTTPDate.parse("Sun Nov  6 08:49:37 1994") == expected)
    }

    @Test("HTTPDateTests: rejects values that are not HTTP dates")
    func testInvalid() {
        #expect(HTTPDate.parse("0") == nil)
        #expect(HTTPDate.parse("") == nil)
        #expect(HTTPDate.parse("2026-10-31T10:00:00Z") == nil)
    }
}

extension HTTPDateTests {
    @Test("HTTPDateTests: RFC 9110 §5.6.7 writes the IMF-fixdate format, which parses back")
    func testString() {
        let date = Date(timeIntervalSince1970: 784_111_777)

        #expect(HTTPDate.string(from: date) == "Sun, 06 Nov 1994 08:49:37 GMT")
        #expect(HTTPDate.parse(HTTPDate.string(from: date)) == date)
    }

    @Test("HTTPDateTests: RFC 9110 §6.6.1 adds a Date only when there is none")
    func testAddDateIfMissing() {
        let received = Date(timeIntervalSince1970: 784_111_777)

        var missing = HTTPHeaders()
        missing.addDateIfMissing(received: received)
        #expect(missing.first(name: "Date") == "Sun, 06 Nov 1994 08:49:37 GMT")

        var present: HTTPHeaders = ["Date": "Mon, 07 Nov 1994 08:49:37 GMT"]
        present.addDateIfMissing(received: received)
        #expect(present["Date"] == ["Mon, 07 Nov 1994 08:49:37 GMT"])
    }
}
