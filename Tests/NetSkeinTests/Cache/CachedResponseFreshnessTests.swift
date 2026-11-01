import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import Testing

@testable import NetSkein

struct CachedResponseFreshnessTests {
    let received = Date(timeIntervalSince1970: 1_700_000_000)

    func entry(
        _ headers: HTTPHeaders,
        status: HTTPResponseStatus = .ok,
        requestTime: Date? = nil,
        varying: HTTPHeaders = [:]
    ) -> CachedResponse {
        CachedResponse(
            status: status,
            headers: headers,
            body: ByteBuffer(string: "body"),
            varyingRequestHeaders: varying,
            requestTime: requestTime ?? received,
            responseTime: received,
            isForced: false
        )
    }

    func httpDate(_ date: Date) -> String {
        HTTPDate.string(from: date)
    }
}

// MARK: - Age

extension CachedResponseFreshnessTests {
    @Test("CachedResponseFreshnessTests: §4.2.3 age adds the Age header, delay and resident time")
    func testAgeCalculation() {
        let cached = entry(["Age": "30"], requestTime: received.addingTimeInterval(-2))

        // corrected initial age = 30 + 2 (response delay), plus 10 seconds in the cache
        #expect(cached.age(at: received.addingTimeInterval(10)) == 42)
    }

    @Test("CachedResponseFreshnessTests: §4.2.3 apparent age comes from the Date header")
    func testApparentAge() {
        let cached = entry(["Date": httpDate(received.addingTimeInterval(-100)), "Age": "-5"])

        #expect(cached.age(at: received) == 100)
    }
}

// MARK: - Freshness Lifetime

extension CachedResponseFreshnessTests {
    @Test("CachedResponseFreshnessTests: §4.2.1 max-age wins over Expires")
    func testMaxAgeWins() {
        let cached = entry([
            "Cache-Control": "max-age=60",
            "Expires": httpDate(received.addingTimeInterval(600)),
        ])

        #expect(cached.freshnessLifetime(defaultTTL: nil) == 60)
    }

    @Test("CachedResponseFreshnessTests: §4.2.1 Expires is measured from the Date header")
    func testExpires() {
        let cached = entry([
            "Date": httpDate(received),
            "Expires": httpDate(received.addingTimeInterval(300)),
        ])

        #expect(cached.freshnessLifetime(defaultTTL: nil) == 300)
    }

    @Test("CachedResponseFreshnessTests: §4.2.1 without Date, Expires is measured from receipt")
    func testExpiresWithoutDate() {
        let cached = entry(["Expires": httpDate(received.addingTimeInterval(120))])

        #expect(cached.freshnessLifetime(defaultTTL: nil) == 120)
    }

    @Test("CachedResponseFreshnessTests: §5.3 an invalid Expires means already expired")
    func testInvalidExpires() {
        let cached = entry(["Expires": "0"])

        #expect(cached.freshnessLifetime(defaultTTL: .seconds(60)) == 0)
    }

    @Test(
        "CachedResponseFreshnessTests: §4.2.2 defaultTTL applies to default-cacheable or public responses"
    )
    func testDefaultTTL() {
        #expect(entry([:]).freshnessLifetime(defaultTTL: .seconds(60)) == 60)
        #expect(entry([:]).freshnessLifetime(defaultTTL: nil) == 0)
        #expect(
            entry([:], status: .internalServerError).freshnessLifetime(defaultTTL: .seconds(60))
                == 0
        )
        #expect(
            entry(["Cache-Control": "public"], status: .internalServerError)
                .freshnessLifetime(defaultTTL: .seconds(60)) == 60
        )
    }
}

// MARK: - Vary and Headers

extension CachedResponseFreshnessTests {
    @Test("CachedResponseFreshnessTests: §4.1 matches on the headers named by Vary")
    func testVaryMatching() {
        let cached = entry(
            ["Vary": "Accept-Language, accept-encoding"],
            varying: ["Accept-Language": "en", "Accept-Encoding": "gzip"]
        )

        #expect(cached.matches(["accept-language": "en", "Accept-Encoding": "gzip"]))
        #expect(!cached.matches(["Accept-Language": "fr", "Accept-Encoding": "gzip"]))
        #expect(!cached.matches(["Accept-Encoding": "gzip"]))
        #expect(!entry(["Vary": "*"]).matches([:]))
    }

    @Test(
        "CachedResponseFreshnessTests: §3.1 drops hop-by-hop fields, Set-Cookie and Cache-Status"
    )
    func testStorableHeaders() {
        let stored = HTTPHeaders.storable(
            [
                "Connection": "close, X-Hop",
                "X-Hop": "1",
                "Keep-Alive": "timeout=5",
                "Transfer-Encoding": "chunked",
                "Set-Cookie": "a=b",
                "Cache-Status": "CDN; hit",
                "ETag": "\"v1\"",
            ],
            decompressedBodyLength: nil
        )

        #expect(stored.map(\.name) == ["ETag"])
    }

    @Test("CachedResponseFreshnessTests: fixes headers of a body the transport decompressed")
    func testDecompressedHeaders() {
        let compressed: HTTPHeaders = ["Content-Encoding": "gzip", "Content-Length": "20"]

        let decompressed = HTTPHeaders.storable(compressed, decompressedBodyLength: 120)
        #expect(!decompressed.contains(name: "Content-Encoding"))
        #expect(decompressed.first(name: "Content-Length") == "120")

        let untouched = HTTPHeaders.storable(compressed, decompressedBodyLength: nil)
        #expect(untouched.first(name: "Content-Encoding") == "gzip")
    }

    @Test("CachedResponseFreshnessTests: §4.2.3 a 304 restarts the age from its own Age and Date")
    func testRefreshedAge() {
        let cached = entry([
            "Cache-Control": "max-age=600",
            "Age": "500",
            "Date": httpDate(received.addingTimeInterval(-500)),
        ])
        let later = received.addingTimeInterval(900)

        let withoutDate = cached.refreshed(with: [:], requestTime: later, responseTime: later)
        #expect(!withoutDate.headers.contains(name: "Age"))
        #expect(withoutDate.headers.first(name: "Date") == httpDate(later))
        #expect(withoutDate.age(at: later) == 0)

        let withDate = cached.refreshed(
            with: ["Date": httpDate(later.addingTimeInterval(-3)), "Age": "2"],
            requestTime: later,
            responseTime: later
        )
        #expect(withDate.headers.first(name: "Age") == "2")
        #expect(withDate.age(at: later) == 3)
    }

    @Test(
        "CachedResponseFreshnessTests: §3.2 a 304 replaces stored headers except the body's own"
    )
    func testRefreshedHeaders() {
        let cached = entry([
            "ETag": "\"v1\"", "Cache-Control": "max-age=1", "Content-Length": "4", "X-Keep": "1",
        ])
        let later = received.addingTimeInterval(50)

        let refreshed = cached.refreshed(
            with: [
                "Cache-Control": "max-age=60", "Content-Length": "0",
                "Content-Encoding": "gzip", "Set-Cookie": "a=b",
            ],
            requestTime: later,
            responseTime: later
        )

        #expect(refreshed.headers.first(name: "Cache-Control") == "max-age=60")
        #expect(refreshed.headers.first(name: "Content-Length") == "4")
        #expect(!refreshed.headers.contains(name: "Content-Encoding"))
        #expect(!refreshed.headers.contains(name: "Set-Cookie"))
        #expect(refreshed.headers.first(name: "X-Keep") == "1")
        #expect(refreshed.responseTime == later)
        #expect(refreshed.body == cached.body)
    }

    @Test("CachedResponseFreshnessTests: §5.1 a served response carries Age and Cache-Status")
    func testServedResponse() {
        let response = entry(["Age": "3"])
            .served(at: received.addingTimeInterval(7), cacheStatus: "NetSkein; hit")

        #expect(response.headers.first(name: "Age") == "10")
        #expect(response.headers.netSkeinCacheStatus == "hit")
    }

    @Test("CachedResponseFreshnessTests: finds this cache's member among others in Cache-Status")
    func testCacheStatusLookup() {
        let headers: HTTPHeaders = [
            "Cache-Status": "CDN; fwd=miss, NetSkein; fwd=uri-miss; stored"
        ]

        #expect(headers.netSkeinCacheStatus == "fwd=uri-miss; stored")
        #expect(HTTPHeaders([("Cache-Status", "CDN; hit")]).netSkeinCacheStatus == nil)
    }
}
