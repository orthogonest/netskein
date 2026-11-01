import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import NetSkein
import NetSkeinTesting
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Uses only the public API, the way an app's tests would.
struct CacheTestingTests {
    let url = "https://api.example.com/items"

    func cacheableStub() -> HTTPStub {
        HTTPStub(
            method: .GET,
            url: url,
            outcome: .response(status: .ok, headers: ["Cache-Control": "max-age=60"], body: nil)
        )
    }
}

// MARK: - Test Clock

extension CacheTestingTests {
    @Test("CacheTestingTests: TestClock stays put until advanced")
    func testClock() {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = TestClock(start: start)

        #expect(clock.now == start)
        clock.advance(by: .milliseconds(1_500))
        #expect(clock.now == start.addingTimeInterval(1.5))
        #expect(TestClock().now == TestClock().now)
    }

    @Test("CacheTestingTests: advancing the clock makes a cached response stale without waiting")
    func testCacheFollowsClock() async throws {
        let clock = TestClock()
        let client = NetSkeinClient.testing()
            .cache(.testing(clock: clock))
            .addStub(cacheableStub())
            .build()

        _ = try await client.get(url).send()
        clock.advance(by: .seconds(59))
        let fresh = try await client.get(url).send()
        clock.advance(by: .seconds(2))
        let stale = try await client.get(url).send()

        #expect(fresh.headers.first(name: "Cache-Status") == "NetSkein; hit")
        #expect(fresh.headers.first(name: "Age") == "59")
        #expect(
            stale.headers.first(name: "Cache-Status")
                == "NetSkein; fwd=stale; fwd-status=200; stored"
        )
        #expect(client.mock?.requests.count == 2)
    }

    @Test("CacheTestingTests: HTTPCache.testing passes its options to the cache")
    func testCacheOptions() async throws {
        let client = NetSkeinClient.testing()
            .cache(
                .testing(
                    clock: TestClock(),
                    storage: MemoryCacheStorage(maxBytes: 1_000),
                    maxEntryBytes: 100,
                    defaultTTL: .seconds(5),
                    maxStaleOnError: .seconds(5),
                    defaultPolicy: .onlyIfCached
                )
            )
            .build()

        let response = try await client.get(url).send()

        #expect(response.status == .gatewayTimeout)
        #expect(client.mock?.requests.isEmpty == true)
    }
}

// MARK: - Recorded Requests

extension CacheTestingTests {
    @Test("CacheTestingTests: the mock records every request it receives, in order")
    func testRecordedRequests() async throws {
        let client = NetSkeinClient.testing().addStub(cacheableStub()).build()

        _ = try await client.get(url).header("X-Trace", "1").send()
        await #expect(throws: NetSkeinError.self) {
            _ = try await client.get("https://api.example.com/unstubbed").retry(.disabled).send()
        }

        let requests = client.mock?.requests ?? []
        #expect(requests.map(\.url) == [url, "https://api.example.com/unstubbed"])
        #expect(requests.first?.method == .GET)
        #expect(requests.first?.headers.first(name: "X-Trace") == "1")
    }

    @Test("CacheTestingTests: a client that is not a test client has no mock")
    func testNoMockForProductionClient() async throws {
        let client = NetSkeinClient.builder().build()

        #expect(client.mock == nil)

        try await client.shutdown()
    }
}
