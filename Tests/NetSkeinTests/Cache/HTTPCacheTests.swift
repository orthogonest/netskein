import AsyncHTTPClient
import InMemoryTracing
import Logging
import NIOCore
import NIOHTTP1
import Testing
import Tracing

@testable import NetSkein
@testable import NetSkeinTesting

struct HTTPCacheTests {
    let clock = TestClock()
}

// MARK: - Storing and Reusing

extension HTTPCacheTests {
    @Test("HTTPCacheTests: §4.2 a fresh response is reused without going to the network")
    func testFreshHit() async throws {
        let transport = ScriptedTransport([
            .response(.ok, ["Cache-Control": "max-age=60"], body: "first")
        ])
        let client = makeClient(transport, cache: makeCache(clock: clock))

        let miss = try await client.get(itemsURL).send()
        clock.advance(by: .seconds(10))
        let hit = try await client.get(itemsURL).send()

        #expect(miss.cacheStatus == "fwd=uri-miss; stored")
        #expect(hit.cacheStatus == "hit")
        #expect(hit.text() == "first")
        #expect(hit.headers.first(name: "Age") == "10")
        #expect(transport.requests.count == 1)
    }

    @Test("HTTPCacheTests: §4.2.4 a stale response goes back to the network")
    func testStaleGoesToNetwork() async throws {
        let transport = ScriptedTransport([
            .response(.ok, ["Cache-Control": "max-age=60"], body: "first"),
            .response(.ok, ["Cache-Control": "max-age=60"], body: "second"),
        ])
        let client = makeClient(transport, cache: makeCache(clock: clock))

        _ = try await client.get(itemsURL).send()
        clock.advance(by: .seconds(60))
        let response = try await client.get(itemsURL).send()

        #expect(response.cacheStatus == "fwd=stale; fwd-status=200; stored")
        #expect(response.text() == "second")
    }

    @Test("HTTPCacheTests: §4.1 Vary keeps one entry per variant")
    func testVaryVariants() async throws {
        let headers: HTTPHeaders = ["Cache-Control": "max-age=60", "Vary": "Accept-Language"]
        let transport = ScriptedTransport([
            .response(.ok, headers, body: "en"), .response(.ok, headers, body: "fr"),
        ])
        let client = makeClient(transport, cache: makeCache(clock: clock))

        _ = try await client.get(itemsURL).header("Accept-Language", "en").send()
        let french = try await client.get(itemsURL).header("Accept-Language", "fr").send()
        let english = try await client.get(itemsURL).header("Accept-Language", "en").send()

        #expect(french.cacheStatus == "fwd=vary-miss; stored")
        #expect(english.cacheStatus == "hit")
        #expect(english.text() == "en")
    }

    @Test("HTTPCacheTests: §4.1 Vary is matched against headers added by middleware")
    func testVaryUsesMiddlewareHeaders() async throws {
        let transport = ScriptedTransport([
            .response(.ok, ["Cache-Control": "max-age=60", "Vary": "X-Tenant"], body: "a")
        ])
        let addTenant = ClosureMiddleware { request, _, next in
            var request = request
            request.headers.replaceOrAdd(name: "X-Tenant", value: "acme")
            return try await next(request)
        }
        let client = makeClient(
            transport,
            cache: makeCache(clock: clock),
            middlewares: [addTenant]
        )

        _ = try await client.get(itemsURL).send()
        let hit = try await client.get(itemsURL).send()

        #expect(hit.cacheStatus == "hit")
    }

    @Test("HTTPCacheTests: §4.2.2 defaultTTL keeps a response without freshness information fresh")
    func testDefaultTTL() async throws {
        let transport = ScriptedTransport([.response(.ok, body: "first")])
        let client = makeClient(transport, cache: makeCache(clock: clock, defaultTTL: .seconds(30)))

        _ = try await client.get(itemsURL).send()
        clock.advance(by: .seconds(29))
        let hit = try await client.get(itemsURL).send()

        #expect(hit.cacheStatus == "hit")
    }

    @Test(
        "HTTPCacheTests: §5.2.2.4 qualified no-cache revalidates like no-cache, keeping every header"
    )
    func testQualifiedNoCache() async throws {
        let transport = ScriptedTransport([
            .response(
                .ok,
                [
                    "Cache-Control": #"max-age=60, no-cache="X-Secret""#, "ETag": "\"v1\"",
                    "X-Secret": "1",
                ]
            ),
            .response(.notModified, ["ETag": "\"v1\""]),
        ])
        let client = makeClient(transport, cache: makeCache(clock: clock))

        _ = try await client.get(itemsURL).send()
        let reused = try await client.get(itemsURL).send()

        #expect(reused.cacheStatus == "fwd=stale; fwd-status=304; stored")
        #expect(reused.headers.first(name: "X-Secret") == "1")
    }

    @Test("HTTPCacheTests: RFC 9110 §6.6.1 a stored response without Date gets the time it arrived")
    func testStoredDate() async throws {
        let serverDate = HTTPDate.string(from: clock.now.addingTimeInterval(-5))
        let transport = ScriptedTransport([
            .response(.ok, ["Cache-Control": "max-age=60"], body: "a"),
            .response(.ok, ["Cache-Control": "max-age=60", "Date": serverDate], body: "b"),
        ])
        let client = makeClient(transport, cache: makeCache(clock: clock))
        let arrived = HTTPDate.string(from: clock.now)

        _ = try await client.get(itemsURL).send()
        let added = try await client.get(itemsURL).send()
        _ = try await client.get("https://api.example.com/dated").send()
        let kept = try await client.get("https://api.example.com/dated").send()

        #expect(added.cacheStatus == "hit")
        #expect(added.headers.first(name: "Date") == arrived)
        #expect(kept.headers["Date"] == [serverDate])
    }

    @Test("HTTPCacheTests: never stores Set-Cookie, so hits do not replay cookies")
    func testSetCookieNotStored() async throws {
        let transport = ScriptedTransport([
            .response(.ok, ["Cache-Control": "max-age=60", "Set-Cookie": "session=1"])
        ])
        let client = makeClient(transport, cache: makeCache(clock: clock))

        let miss = try await client.get(itemsURL).send()
        let hit = try await client.get(itemsURL).send()

        #expect(miss.headers.first(name: "Set-Cookie") == "session=1")
        #expect(!hit.headers.contains(name: "Set-Cookie"))
    }

    @Test("HTTPCacheTests: stores the decompressed body with matching headers")
    func testDecompressedBody() async throws {
        let transport = ScriptedTransport([
            .response(
                .ok,
                ["Cache-Control": "max-age=60", "Content-Encoding": "gzip", "Content-Length": "3"],
                body: "decompressed"
            )
        ])
        let client = makeClient(
            transport,
            cache: makeCache(clock: clock),
            transportDecompresses: true
        )

        _ = try await client.get(itemsURL).send()
        let hit = try await client.get(itemsURL).send()

        #expect(hit.text() == "decompressed")
        #expect(!hit.headers.contains(name: "Content-Encoding"))
        #expect(hit.headers.first(name: "Content-Length") == "12")
    }
}

// MARK: - What Is Not Stored

extension HTTPCacheTests {
    @Test(
        "HTTPCacheTests: §3 responses are not stored for no-store, Vary *, 206, redirects or no freshness",
        arguments: [
            ScriptedTransport.Reply.response(.ok, ["Cache-Control": "no-store"]),
            .response(.ok, ["Cache-Control": "max-age=60", "Vary": "*"]),
            .response(.partialContent, ["Cache-Control": "max-age=60"]),
            .response(.ok, ["Cache-Control": "max-age=60"], redirected: true),
            .response(.internalServerError),
            .response(.notModified, ["Cache-Control": "max-age=60"]),
            .response(.continue, ["Cache-Control": "max-age=60"]),
        ]
    )
    func testNotStored(reply: ScriptedTransport.Reply) async throws {
        let storage = MemoryCacheStorage(maxBytes: 1024)
        let client = makeClient(
            ScriptedTransport([reply]),
            cache: makeCache(clock: clock, storage: storage)
        )

        let response = try await client.get(itemsURL).send()

        #expect(response.cacheStatus == "fwd=uri-miss")
        #expect(await storage.entries(for: itemsURL).isEmpty)
    }

    @Test(
        "HTTPCacheTests: §3 responses with explicit freshness, public or private are stored",
        arguments: [
            HTTPHeaders([("Cache-Control", "no-store, must-understand, max-age=60")]),
            ["Expires": "Sun, 06 Nov 2094 08:49:37 GMT"],
            ["Cache-Control": "public"],
            ["Cache-Control": "private"],
        ]
    )
    func testStoredWithoutDefaultCacheableStatus(headers: HTTPHeaders) async throws {
        let storage = MemoryCacheStorage(maxBytes: 1024)
        let client = makeClient(
            ScriptedTransport([.response(.created, headers)]),
            cache: makeCache(clock: clock, storage: storage)
        )

        _ = try await client.get(itemsURL).send()

        #expect(await storage.entries(for: itemsURL).count == 1)
    }

    @Test("HTTPCacheTests: §5.2.1.5 request no-store prevents storing")
    func testRequestNoStore() async throws {
        let storage = MemoryCacheStorage(maxBytes: 1024)
        let client = makeClient(
            ScriptedTransport([.response(.ok, ["Cache-Control": "max-age=60"])]),
            cache: makeCache(clock: clock, storage: storage)
        )

        _ = try await client.get(itemsURL).header("Cache-Control", "no-store").send()

        #expect(await storage.entries(for: itemsURL).isEmpty)
    }

    @Test("HTTPCacheTests: bodies above maxEntryBytes are returned whole but not stored")
    func testLargeBodyNotStored() async throws {
        let storage = MemoryCacheStorage(maxBytes: 1024)
        let body = String(repeating: "x", count: 50)
        let client = makeClient(
            ScriptedTransport([.response(.ok, ["Cache-Control": "max-age=60"], body: body)]),
            cache: makeCache(clock: clock, storage: storage, maxEntryBytes: 10)
        )

        let response = try await client.get(itemsURL).send()

        #expect(response.text() == body)
        #expect(response.cacheStatus == "fwd=uri-miss")
        #expect(await storage.entries(for: itemsURL).isEmpty)
    }

    @Test("HTTPCacheTests: bodies above maxResponseBytes fail as a network failure")
    func testBodyAboveResponseLimit() async throws {
        let client = makeClient(
            ScriptedTransport([.response(.ok, ["Cache-Control": "max-age=60"], body: "too long")]),
            cache: makeCache(clock: clock)
        )

        await #expect {
            _ = try await client.get(itemsURL).maxResponseBytes(3).send()
        } throws: { error in
            (error as? NetSkeinError)?.kind == .networkFailure
        }
    }
}

// MARK: - What Bypasses the Cache

extension HTTPCacheTests {
    @Test("HTTPCacheTests: requests the cache cannot answer go straight to the network")
    func testBypass() async throws {
        let transport = ScriptedTransport(
            Array(repeating: .response(.ok, ["Cache-Control": "max-age=60"]), count: 5)
        )
        let storage = MemoryCacheStorage(maxBytes: 1024)
        let client = makeClient(transport, cache: makeCache(clock: clock, storage: storage))

        let relative = try await client.get("/relative").send()
        let head = try await client.request(.HEAD, url: itemsURL).send()
        let conditional = try await client.get(itemsURL).header("If-None-Match", "\"v1\"").send()
        let withBody = try await client.get(itemsURL).dangerouslyAllowBody().json(["a": 1]).send()
        let streamed = try await client.get(itemsURL).stream { _, _, _ in }

        #expect(relative.cacheStatus == "fwd=bypass")
        #expect(head.cacheStatus == "fwd=method")
        #expect(conditional.cacheStatus == "fwd=bypass")
        #expect(withBody.cacheStatus == "fwd=bypass")
        #expect(streamed.headers.netSkeinCacheStatus == "fwd=bypass")
        #expect(transport.requests.count == 5)
        #expect(await storage.entries(for: itemsURL).isEmpty)
    }

    @Test("HTTPCacheTests: §4.4 a successful unsafe request invalidates its URL")
    func testUnsafeMethodInvalidates() async throws {
        let transport = ScriptedTransport([
            .response(.ok, ["Cache-Control": "max-age=60"]),
            .response(.internalServerError),
            .response(.created),
        ])
        let storage = MemoryCacheStorage(maxBytes: 1024)
        let client = makeClient(transport, cache: makeCache(clock: clock, storage: storage))

        _ = try await client.get(itemsURL).send()
        let failed = try await client.post(itemsURL).send()
        #expect(failed.cacheStatus == "fwd=method")
        #expect(await storage.entries(for: itemsURL).count == 1)

        _ = try await client.post(itemsURL).send()
        #expect(await storage.entries(for: itemsURL).isEmpty)
    }
}

// MARK: - Validation

extension HTTPCacheTests {
    @Test("HTTPCacheTests: §4.3 a stale response is revalidated and a 304 reuses its body")
    func testRevalidationNotModified() async throws {
        let lastModified = "Sun, 06 Nov 1994 08:49:37 GMT"
        let transport = ScriptedTransport([
            .response(
                .ok,
                ["Cache-Control": "max-age=1", "ETag": "W/\"v1\"", "Last-Modified": lastModified],
                body: "cached"
            ),
            .response(.notModified, ["Cache-Control": "max-age=60", "ETag": "\"v1\""]),
        ])
        let client = makeClient(transport, cache: makeCache(clock: clock))

        _ = try await client.get(itemsURL).send()
        clock.advance(by: .seconds(5))
        let revalidated = try await client.get(itemsURL).send()
        let hit = try await client.get(itemsURL).send()

        let conditional = transport.requests[1].headers
        #expect(conditional.first(name: "If-None-Match") == "W/\"v1\"")
        #expect(conditional.first(name: "If-Modified-Since") == lastModified)
        #expect(revalidated.status == .ok)
        #expect(revalidated.text() == "cached")
        #expect(revalidated.cacheStatus == "fwd=stale; fwd-status=304; stored")
        #expect(hit.cacheStatus == "hit")
    }

    @Test("HTTPCacheTests: §4.2.3 a revalidated copy is fresh again despite its old Age")
    func testRevalidationRestartsAge() async throws {
        let transport = ScriptedTransport([
            .response(.ok, ["Cache-Control": "max-age=600", "Age": "500", "ETag": "\"v1\""]),
            .response(.notModified, ["ETag": "\"v1\""]),
        ])
        let client = makeClient(transport, cache: makeCache(clock: clock))

        _ = try await client.get(itemsURL).send()
        clock.advance(by: .seconds(150))
        let revalidated = try await client.get(itemsURL).send()
        clock.advance(by: .seconds(200))
        let hit = try await client.get(itemsURL).send()

        #expect(revalidated.cacheStatus == "fwd=stale; fwd-status=304; stored")
        #expect(hit.cacheStatus == "hit")
        #expect(hit.headers.first(name: "Age") == "200")
    }

    @Test("HTTPCacheTests: §4.3.4 a 304 for another representation fetches it in full")
    func testRevalidationMismatch() async throws {
        let transport = ScriptedTransport([
            .response(.ok, ["Cache-Control": "max-age=1", "ETag": "\"v1\""], body: "old"),
            .response(.notModified, ["ETag": "\"v2\""]),
            .response(.ok, ["Cache-Control": "max-age=60", "ETag": "\"v2\""], body: "new"),
        ])
        let client = makeClient(transport, cache: makeCache(clock: clock))

        _ = try await client.get(itemsURL).send()
        clock.advance(by: .seconds(5))
        let response = try await client.get(itemsURL).send()

        #expect(response.text() == "new")
        #expect(response.cacheStatus == "fwd=stale; fwd-status=200; stored")
        #expect(!transport.requests[2].headers.contains(name: "If-None-Match"))
    }

    @Test(
        "HTTPCacheTests: §4.3.4 a 304 matches by Last-Modified, or by default without validators",
        arguments: [
            (["Last-Modified": "a"] as HTTPHeaders, "a", true),
            (["Last-Modified": "b"] as HTTPHeaders, "a", false),
            ([:] as HTTPHeaders, "a", true),
        ]
    )
    func testNotModifiedMatching(
        notModified: HTTPHeaders,
        stored: String,
        matches: Bool
    ) async throws {
        let transport = ScriptedTransport([
            .response(.ok, ["Cache-Control": "max-age=1", "Last-Modified": stored], body: "old"),
            .response(.notModified, notModified),
            .response(.ok, body: "new"),
        ])
        let client = makeClient(transport, cache: makeCache(clock: clock))

        _ = try await client.get(itemsURL).send()
        clock.advance(by: .seconds(5))
        let response = try await client.get(itemsURL).send()

        #expect(response.text() == (matches ? "old" : "new"))
    }

    @Test("HTTPCacheTests: §5.2.1.5 a 304 is not stored for a no-store request")
    func testNotModifiedWithRequestNoStore() async throws {
        let transport = ScriptedTransport([
            .response(.ok, ["Cache-Control": "max-age=1", "ETag": "\"v1\""], body: "cached"),
            .response(.notModified, ["Cache-Control": "max-age=60", "ETag": "\"v1\""]),
            .response(.ok, body: "network"),
        ])
        let client = makeClient(transport, cache: makeCache(clock: clock))

        _ = try await client.get(itemsURL).send()
        clock.advance(by: .seconds(5))
        let revalidated = try await client.get(itemsURL).header("Cache-Control", "no-store").send()
        let next = try await client.get(itemsURL).send()

        #expect(revalidated.text() == "cached")
        #expect(revalidated.cacheStatus == "fwd=stale; fwd-status=304")
        #expect(next.text() == "network")
    }

    @Test("HTTPCacheTests: §5.2.2.4 unqualified no-cache always revalidates")
    func testResponseNoCache() async throws {
        let transport = ScriptedTransport([
            .response(.ok, ["Cache-Control": "max-age=60, no-cache", "ETag": "\"v1\""]),
            .response(.notModified, ["ETag": "\"v1\""]),
        ])
        let client = makeClient(transport, cache: makeCache(clock: clock))

        _ = try await client.get(itemsURL).send()
        let response = try await client.get(itemsURL).send()

        #expect(response.cacheStatus == "fwd=stale; fwd-status=304; stored")
    }
}

// MARK: - Request Directives and Policies

extension HTTPCacheTests {
    @Test(
        "HTTPCacheTests: §5.2.1 request directives force the request to the network",
        arguments: [
            ("no-cache", CachePolicy.default, "fwd=request"),
            ("", .reloadIgnoringCache, "fwd=request"),
            ("max-age=5", .default, "fwd=request"),
            ("min-fresh=55", .default, "fwd=request"),
            ("max-stale=1", .default, "fwd=stale"),
        ]
    )
    func testRequestDirectivesGoToNetwork(
        cacheControl: String,
        policy: CachePolicy,
        reason: String
    ) async throws {
        let transport = ScriptedTransport([
            .response(.ok, ["Cache-Control": "max-age=60"]),
            .response(.ok, ["Cache-Control": "max-age=60"]),
        ])
        let client = makeClient(transport, cache: makeCache(clock: clock))
        _ = try await client.get(itemsURL).send()
        clock.advance(by: .seconds(cacheControl == "max-stale=1" ? 70 : 10))

        var request = client.get(itemsURL).cachePolicy(policy)
        if !cacheControl.isEmpty { request = request.header("Cache-Control", cacheControl) }
        let response = try await request.send()

        #expect(response.cacheStatus == "\(reason); fwd-status=200; stored")
    }

    @Test("HTTPCacheTests: §5.4 Pragma no-cache counts only without Cache-Control")
    func testPragma() async throws {
        let transport = ScriptedTransport([
            .response(.ok, ["Cache-Control": "max-age=60"]),
            .response(.ok, ["Cache-Control": "max-age=60"]),
        ])
        let client = makeClient(transport, cache: makeCache(clock: clock))
        _ = try await client.get(itemsURL).send()

        let ignored = try await client.get(itemsURL)
            .header("Pragma", "no-cache").header("Cache-Control", "max-stale=0").send()
        let honoured = try await client.get(itemsURL).header("Pragma", "no-cache").send()

        #expect(ignored.cacheStatus == "hit")
        #expect(honoured.cacheStatus == "fwd=request; fwd-status=200; stored")
    }

    @Test("HTTPCacheTests: §4.2.4 max-stale accepts a stale response unless must-revalidate")
    func testMaxStale() async throws {
        let transport = ScriptedTransport([
            .response(.ok, ["Cache-Control": "max-age=10"], body: "stale"),
            .response(.ok, ["Cache-Control": "max-age=10, must-revalidate"], body: "strict"),
        ])
        let client = makeClient(transport, cache: makeCache(clock: clock))
        _ = try await client.get(itemsURL).send()
        clock.advance(by: .seconds(20))

        let unlimited = try await client.get(itemsURL).cachePolicy(.returnCacheElseLoad).send()
        let bounded = try await client.get(itemsURL).header("Cache-Control", "max-stale=15").send()
        let anyAge = try await client.get(itemsURL).header("Cache-Control", "max-stale").send()
        #expect(unlimited.cacheStatus == "hit")
        #expect(bounded.cacheStatus == "hit")
        #expect(anyAge.cacheStatus == "hit")

        // The second response replaces the first and forbids serving it stale
        _ = try await client.get(itemsURL).header("Cache-Control", "no-cache").send()
        clock.advance(by: .seconds(20))
        await #expect(throws: NetSkeinError.self) {
            _ = try await client.get(itemsURL).cachePolicy(.returnCacheElseLoad).send()
        }
    }

    @Test("HTTPCacheTests: §5.2.1.7 only-if-cached answers 504 without a usable response")
    func testOnlyIfCached() async throws {
        let transport = ScriptedTransport([.response(.ok, ["Cache-Control": "max-age=10"])])
        let client = makeClient(transport, cache: makeCache(clock: clock))

        let empty = try await client.get(itemsURL).cachePolicy(.onlyIfCached).send()
        _ = try await client.get(itemsURL).send()
        clock.advance(by: .seconds(20))
        let stale = try await client.get(itemsURL).cachePolicy(.onlyIfCached).send()
        let strict = try await client.get(itemsURL).header("Cache-Control", "only-if-cached").send()

        #expect(empty.status == .gatewayTimeout)
        #expect(empty.cacheStatus == "detail=only-if-cached")
        #expect(stale.cacheStatus == "hit")
        #expect(strict.status == .gatewayTimeout)
        #expect(transport.requests.count == 1)
    }

    @Test(
        "HTTPCacheTests: fresh(for:) caches against the server's headers, apart from other requests"
    )
    func testForcedFreshness() async throws {
        let transport = ScriptedTransport([
            .response(.ok, ["Cache-Control": "no-store"], body: "forced"),
            .response(.ok, ["Cache-Control": "no-store"], body: "normal"),
            .response(.notFound, body: "missing"),
        ])
        let client = makeClient(transport, cache: makeCache(clock: clock))

        _ = try await client.get(itemsURL).cachePolicy(.fresh(for: .minutes(5))).send()
        let normal = try await client.get(itemsURL).send()
        let forced = try await client.get(itemsURL).cachePolicy(.fresh(for: .minutes(5))).send()
        clock.advance(by: .seconds(301))
        let expired = try await client.get(itemsURL).cachePolicy(.fresh(for: .minutes(5))).send()

        #expect(normal.text() == "normal")
        #expect(normal.cacheStatus == "fwd=uri-miss")
        #expect(forced.text() == "forced")
        #expect(forced.cacheStatus == "hit")
        #expect(expired.text() == "missing")
        #expect(expired.cacheStatus == "fwd=stale; fwd-status=404")
    }
}

// MARK: - Policies

extension HTTPCacheTests {
    @Test(
        "HTTPCacheTests: returnCacheElseLoad and onlyIfCached also use responses stored with fresh(for:)",
        arguments: [CachePolicy.returnCacheElseLoad, .onlyIfCached]
    )
    func testAnyAgePoliciesUseForcedEntries(policy: CachePolicy) async throws {
        let transport = ScriptedTransport([
            .response(.ok, ["Cache-Control": "no-store"], body: "countries")
        ])
        let client = makeClient(transport, cache: makeCache(clock: clock))

        _ = try await client.get(itemsURL).cachePolicy(.fresh(for: .minutes(5))).send()
        clock.advance(by: .seconds(3600))
        let offline = try await client.get(itemsURL).cachePolicy(policy).send()

        #expect(offline.text() == "countries")
        #expect(offline.cacheStatus == "hit")
        #expect(transport.requests.count == 1)
    }

    @Test("HTTPCacheTests: reloadIgnoringCache sends no-cache, with or without a cache")
    func testReloadSendsNoCache() async throws {
        let cached = ScriptedTransport([
            .response(.ok, ["Cache-Control": "max-age=60"]),
            .response(.ok, ["Cache-Control": "max-age=60"]),
        ])
        let client = makeClient(cached, cache: makeCache(clock: clock))
        _ = try await client.get(itemsURL).send()
        let reloaded = try await client.get(itemsURL).cachePolicy(.reloadIgnoringCache).send()

        let uncached = ScriptedTransport([.response(.ok)])
        let plainClient = NetSkeinClient(
            transport: uncached,
            logger: Logger(label: LoggerLabel.test)
        )
        _ = try await plainClient.get(itemsURL).cachePolicy(.reloadIgnoringCache).send()

        #expect(reloaded.cacheStatus == "fwd=request; fwd-status=200; stored")
        #expect(cached.requests[1].headers.first(name: "Cache-Control") == "no-cache")
        #expect(uncached.requests[0].headers.first(name: "Cache-Control") == "no-cache")
    }

    @Test("HTTPCacheTests: noStore reads the cache but never stores, and sends no-store")
    func testNoStorePolicy() async throws {
        let transport = ScriptedTransport([
            .response(.ok, ["Cache-Control": "max-age=60"], body: "secret"),
            .response(.ok, ["Cache-Control": "max-age=60"], body: "public"),
        ])
        let storage = MemoryCacheStorage(maxBytes: 1024)
        let client = makeClient(transport, cache: makeCache(clock: clock, storage: storage))

        let secret = try await client.get(itemsURL).cachePolicy(.noStore).send()
        #expect(await storage.entries(for: itemsURL).isEmpty)
        #expect(transport.requests[0].headers.first(name: "Cache-Control") == "no-store")

        _ = try await client.get(itemsURL).send()
        let reused = try await client.get(itemsURL).cachePolicy(.noStore).send()

        #expect(secret.cacheStatus == "fwd=uri-miss")
        #expect(reused.cacheStatus == "hit")
        #expect(reused.text() == "public")
    }

    @Test("HTTPCacheTests: defaultPolicy applies to requests without their own, and can change")
    func testDefaultPolicy() async throws {
        let transport = ScriptedTransport([.response(.ok, ["Cache-Control": "max-age=1"])])
        let cache = makeCache(clock: clock, defaultPolicy: .onlyIfCached)
        let client = makeClient(transport, cache: cache)

        let offline = try await client.get(itemsURL).send()
        #expect(offline.status == .gatewayTimeout)

        let explicit = try await client.get(itemsURL).cachePolicy(.default).send()
        #expect(explicit.cacheStatus == "fwd=uri-miss; stored")

        clock.advance(by: .seconds(10))
        let stale = try await client.get(itemsURL).send()
        #expect(stale.cacheStatus == "hit")

        cache.defaultPolicy = .default
        #expect(cache.defaultPolicy == .default)
        await #expect(throws: NetSkeinError.self) {
            _ = try await client.get(itemsURL).send()
        }
    }
}

// MARK: - Serving Stale on Error

extension HTTPCacheTests {
    @Test(
        "HTTPCacheTests: RFC 5861 §4 maxStaleOnError answers failures and outages with the stale response"
    )
    func testStaleOnError() async throws {
        let transport = ScriptedTransport([
            .response(.ok, ["Cache-Control": "max-age=1"], body: "stale"),
            .failure,
            .response(.serviceUnavailable, body: "down"),
        ])
        let client = makeClient(
            transport,
            cache: makeCache(clock: clock, maxStaleOnError: .hours(1))
        )
        _ = try await client.get(itemsURL).send()
        clock.advance(by: .seconds(5))

        let afterFailure = try await client.get(itemsURL).send()
        let afterOutage = try await client.get(itemsURL).send()

        #expect(afterFailure.text() == "stale")
        #expect(afterFailure.cacheStatus == "fwd=stale; detail=error")
        #expect(afterOutage.text() == "stale")
    }

    @Test(
        "HTTPCacheTests: failures are thrown when stale responses may not be served",
        arguments: [
            (["Cache-Control": "max-age=1"] as HTTPHeaders, TimeAmount?.none),
            (["Cache-Control": "max-age=1, must-revalidate"] as HTTPHeaders, .hours(1)),
            (["Cache-Control": "max-age=1, no-cache"] as HTTPHeaders, .hours(1)),
            (["Cache-Control": "max-age=1"] as HTTPHeaders, .seconds(3)),
        ]
    )
    func testNoStaleOnError(headers: HTTPHeaders, maxStaleOnError: TimeAmount?) async throws {
        let transport = ScriptedTransport([.response(.ok, headers), .failure])
        let client = makeClient(
            transport,
            cache: makeCache(clock: clock, maxStaleOnError: maxStaleOnError)
        )
        _ = try await client.get(itemsURL).send()
        clock.advance(by: .seconds(5))

        await #expect(throws: NetSkeinError.self) {
            _ = try await client.get(itemsURL).send()
        }
    }

    @Test("HTTPCacheTests: a 5xx is returned as is when stale responses may not be served")
    func testServerErrorWithoutStale() async throws {
        let transport = ScriptedTransport([
            .response(.ok, ["Cache-Control": "max-age=1"]),
            .response(.serviceUnavailable, body: "down"),
        ])
        let client = makeClient(transport, cache: makeCache(clock: clock))
        _ = try await client.get(itemsURL).send()
        clock.advance(by: .seconds(5))

        let response = try await client.get(itemsURL).send()

        #expect(response.status == .serviceUnavailable)
        #expect(response.cacheStatus == "fwd=stale; fwd-status=503")
    }

    @Test("HTTPCacheTests: RFC 5861 §4 statuses other than 500, 502, 503 and 504 are answers")
    func testNotImplementedIsNotAnOutage() async throws {
        let transport = ScriptedTransport([
            .response(.ok, ["Cache-Control": "max-age=1"]),
            .response(.notImplemented, body: "unsupported"),
        ])
        let client = makeClient(
            transport,
            cache: makeCache(clock: clock, maxStaleOnError: .hours(1))
        )
        _ = try await client.get(itemsURL).send()
        clock.advance(by: .seconds(5))

        let response = try await client.get(itemsURL).send()

        #expect(response.status == .notImplemented)
        #expect(response.cacheStatus == "fwd=stale; fwd-status=501; stored")
    }

    @Test("HTTPCacheTests: a fresh copy stands in when a forced reload fails")
    func testFreshCopyOnFailedReload() async throws {
        let transport = ScriptedTransport([
            .response(.ok, ["Cache-Control": "max-age=60"], body: "cached"),
            .failure,
        ])
        let client = makeClient(
            transport,
            cache: makeCache(clock: clock, maxStaleOnError: .seconds(1))
        )
        _ = try await client.get(itemsURL).send()

        let response = try await client.get(itemsURL).cachePolicy(.reloadIgnoringCache).send()

        #expect(response.text() == "cached")
        #expect(response.cacheStatus == "fwd=stale; detail=error")
    }
}

// MARK: - Clearing, Configuration and Reporting

extension HTTPCacheTests {
    @Test("HTTPCacheTests: remove(url:) and removeAll() clear entries")
    func testRemove() async throws {
        let storage = MemoryCacheStorage(maxBytes: 1024)
        let cache = makeCache(clock: clock, storage: storage)
        let client = makeClient(
            ScriptedTransport(
                Array(repeating: .response(.ok, ["Cache-Control": "max-age=60"]), count: 2)
            ),
            cache: cache
        )
        _ = try await client.get(itemsURL).send()
        _ = try await client.get("https://api.example.com/other").send()

        await cache.remove(url: "HTTPS://API.EXAMPLE.COM:443/items#top")
        await cache.remove(url: "/relative")
        #expect(await storage.entries(for: itemsURL).isEmpty)

        await cache.removeAll()
        #expect(await storage.entries(for: "https://api.example.com/other").isEmpty)
    }

    @Test("HTTPCacheTests: equivalent URLs share one cache key")
    func testCacheKey() {
        #expect(
            HTTPCache.key(for: "HTTPS://API.Example.com:443/items?a=1#top")
                == "https://api.example.com/items?a=1"
        )
        #expect(HTTPCache.key(for: "http://example.com:80/") == "http://example.com/")
        #expect(HTTPCache.key(for: "http://example.com:8080/") == "http://example.com:8080/")
        #expect(HTTPCache.key(for: "/relative") == nil)
    }

    @Test("HTTPCacheTests: the public initializer and both builders accept a cache")
    func testConfiguration() async throws {
        let cache = HTTPCache(defaultTTL: .seconds(5), maxStaleOnError: .hours(1))
        #expect(cache.maxEntryBytes == 1024 * 1024)
        #expect(cache.defaultTTL == .seconds(5))
        #expect(cache.maxStaleOnError == .hours(1))
        #expect(cache.now().timeIntervalSinceNow < 1)
        #expect(cache.defaultPolicy == .default)

        let production = NetSkeinClient.builder().cache(cache).build()
        #expect(production.cache === cache)
        #expect(production.transportDecompresses)
        try await production.shutdown()

        let testing = NetSkeinClient.testing().cache(cache).build()
        #expect(testing.cache === cache)
        #expect(!testing.transportDecompresses)
    }

    @Test("HTTPCacheTests: the cache status is logged and recorded on the span")
    func testReporting() async throws {
        let tracer = InMemoryTracer()
        let client = NetSkeinClient(
            transport: ScriptedTransport([.response(.ok, ["Cache-Control": "max-age=60"])]),
            cache: makeCache(clock: clock),
            tracer: tracer,
            logger: Logger(label: LoggerLabel.test)
        )

        _ = try await client.get(itemsURL).send()

        let span = try #require(tracer.finishedSpans.first)
        #expect(span.attributes.get("netskein.cache_status") == .string("fwd=uri-miss; stored"))
    }
}
