# Testing the Cache

Check how your code behaves with cached responses, without waiting for them to expire.

## Overview

Code that uses an `HTTPCache` behaves differently over time: a response is reused while it is fresh, revalidated once it is stale, and served from the cache when offline. To test that, a test needs to control the cache's clock and see which requests actually reached the network. `NetSkeinTesting` provides both:

- ``TestClock`` only moves when the test advances it.
- ``NetSkein/HTTPCache/testing(clock:storage:maxEntryBytes:defaultTTL:maxStaleOnError:defaultPolicy:)`` builds a cache that reads the time from that clock.
- ``NetSkein/NetSkeinClient/mock`` gives access to the requests the mock transport received. A response served from the cache never reaches it.

### Test freshness and expiry

Stub a response with caching headers, send the request, and advance the clock past its lifetime:

```swift
@Test func refetchesOnceTheProfileExpires() async throws {
    let clock = TestClock()
    let client = NetSkeinClient.testing()
        .cache(.testing(clock: clock))
        .addStub(
            HTTPStub(
                method: .GET,
                url: "https://api.example.com/me",
                outcome: .response(status: .ok, headers: ["Cache-Control": "max-age=60"])
            )
        )
        .build()

    _ = try await client.get("https://api.example.com/me").send()

    clock.advance(by: .seconds(30))
    _ = try await client.get("https://api.example.com/me").send()
    #expect(client.mock?.requests.count == 1)   // still fresh: answered by the cache

    clock.advance(by: .seconds(31))
    _ = try await client.get("https://api.example.com/me").send()
    #expect(client.mock?.requests.count == 2)   // stale: asked the server again
}
```

The test runs instantly: no real time passes.

### Check what the cache did

Every response carries a `Cache-Status` header saying what the cache did with the request, such as `NetSkein; hit` or `NetSkein; fwd=stale; fwd-status=200; stored`. Assert on it when the distinction matters, for example between a fresh hit and a stale response served because the server failed:

```swift
#expect(response.headers.first(name: "Cache-Status") == "NetSkein; fwd=stale; detail=error")
```

### Test offline behaviour

`CachePolicy.onlyIfCached` never contacts the network, so a test can check what your app shows offline. Store a response first, then switch the policy:

```swift
let cache = HTTPCache.testing(clock: clock)
// … send the request once so the response is stored …

cache.defaultPolicy = .onlyIfCached
let offline = try await client.get(url).send()   // served from the cache, however old
```

A URL with nothing stored answers `504 Gateway Timeout` under this policy, which lets you test the "no saved data" path too.

### Choose the storage

By default, ``NetSkein/HTTPCache/testing(clock:storage:maxEntryBytes:defaultTTL:maxStaleOnError:defaultPolicy:)`` keeps responses in memory, so every test starts with an empty cache. To test behaviour across app restarts, give it a `DiskCacheStorage` on a temporary directory, and create a second client with a new storage on the same directory to play the restarted app.

### Limitations

- ``MockHTTPClient/requests`` records each request's method, URL and headers. Request bodies cannot be read back from `HTTPClientRequest`; check them in an ``HTTPStub``'s ``HTTPStub/requestValidator``, or in a middleware.
- `DiskCacheStorage` orders files by their modification time after a restart. That uses the file system's real clock, not the ``TestClock``.
