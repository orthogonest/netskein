# NetSkein

[![Swift 6.2+](https://img.shields.io/badge/Swift-6.2+-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20iOS%20%7C%20tvOS%20%7C%20watchOS%20%7C%20Linux-lightgrey)](#requirements)
[![License](https://img.shields.io/badge/license-Apache--2.0%20%2F%20MIT-blue)](#license)

An async HTTP client for Swift 6, built on [AsyncHTTPClient](https://github.com/swift-server/async-http-client).
NetSkein gives you a fluent request builder, typed errors, retries, caching, middleware, and a test client. And it compiles cleanly under Swift 6 strict concurrency.

> [!NOTE]
> **Why the name NetSkein?**
>
> A _skein_ is a coiled bundle of thread, like the network streams NetSkein keeps in order.
> It is also a flock of birds flying in a V. Swift is named after a bird, so NetSkein is a flock of requests flying together.
> And split it as _Nets-kein_: in German, _kein Netz_ means "no network", which is exactly what `NetSkeinTesting` gives your tests.

> [!IMPORTANT]
> NetSkein is in early development. Until 1.0, minor releases may include breaking changes.

## Requirements

- Swift 6.2 or later (Xcode 26 or later on Apple platforms)
- macOS 12, iOS 15, tvOS 15, watchOS 8, Mac Catalyst 15, or Linux

## Installation

Add NetSkein to your `Package.swift`. Use `NetSkeinTesting` in your test targets only.

```swift
dependencies: [
    .package(url: "https://github.com/orthogonest/netskein", branch: "main"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [.product(name: "NetSkein", package: "netskein")]
    ),
    .testTarget(
        name: "MyAppTests",
        dependencies: [
            "MyApp",
            .product(name: "NetSkeinTesting", package: "netskein"),
        ]
    ),
]
```

## Quick Start

```swift
import NetSkein

struct Profile: Decodable {
    let id: Int
    let username: String
}

let client = NetSkeinClient.builder()
    .connectTimeout(.seconds(5))
    .build()

do {
    let profile = try await client.get("https://api.example.com/me")
        .header("Authorization", "Bearer <token>")
        .query(["version": "2"])
        .send()
        .validate()
        .json(Profile.self)

    print("Hello, \(profile.username)")
} catch {
    print("Request failed:", error)
}

// Shut the client down once all requests are done, even if one failed.
try await client.shutdown()
```

## Features

**Requests and responses**

- Fluent builder for `GET`, `POST`, `PUT`, `PATCH` and `DELETE`, with headers, query parameters and path segments.
- Bodies from JSON, URL-encoded forms, multipart forms or files. The compiler rejects a body on a `GET` or `DELETE`.
- Read a response body as text, bytes or JSON, as many times as you need.
- `.validate()` turns non-2xx responses into errors, optionally decoding the server's error body.
- Every call throws a single typed error, `NetSkeinError`.

**Streaming**

- Upload and download large files with constant memory, with progress reporting.
- Read a response as it arrives, as chunks with `stream()` or as lines with `lines()`, for server-sent events, JSON Lines and logs.
- Resume interrupted downloads with `Range` requests.

**Resilience**

- Timeouts for connecting, reading and writing, for each attempt, and for the whole call including retries.
- Retries with exponential backoff and jitter, honouring `Retry-After`. Off by default; non-idempotent methods are not retried unless you allow it.
- A circuit breaker that fails fast while a server keeps failing.

**Caching**

- RFC 9111 private HTTP cache, in memory or on disk, with revalidation via `ETag` and `Last-Modified`.
- Per-request cache policies, a default TTL for responses without caching headers, and stale responses as a fallback when the network fails.

**Middleware**

- Change requests and responses for every call or for a single request, once per call or once per attempt.
- Built-in middleware to log each request as a `curl` command.

**Connections and security**

- HTTP/2 when the server supports it, or HTTP/1.1 only.
- HTTP and SOCKS proxies, configurable redirect policy, and a cookie jar.
- Custom TLS configuration, including trusted self-signed certificates for development.
- gzip and deflate responses are decompressed by default, with a 10 MB size limit to guard against decompression bombs. Configure it with `.decompressionLimit(_:)`, or turn it off with `.automaticDecompression(false)`.

**Observability**

- Logging through [`swift-log`](https://github.com/apple/swift-log).
- A span for every call through [`swift-distributed-tracing`](https://github.com/apple/swift-distributed-tracing).
- An `X-Request-ID` header on every request, kept the same across retries.

**Testing**

- `NetSkeinTesting` builds clients that answer from stubs instead of the network, and records the requests they receive.
- A test clock to control time for cache and circuit breaker tests.

## Usage

### Streaming

```swift
// Upload a file without loading it into memory.
let upload = try await client.post("https://api.example.com/videos")
    .file(atPath: "/path/to/video.mp4")
    .send()

// Download straight to disk, resuming if the connection drops.
try await client.get("https://example.com/installer.dmg")
    .retry(.standard())
    .download(toFileAtPath: "/path/to/installer.dmg", resumption: .onRetry)

// Read server-sent events line by line.
for try await line in try await client.get("https://api.example.com/events").lines() {
    print(line)
}
```

### Timeouts, Retries, and Circuit Breaker

```swift
let breaker = CircuitBreaker(failureThreshold: 5, openDuration: .seconds(30))

let client = NetSkeinClient.builder()
    .connectTimeout(.seconds(5))
    .callTimeout(.seconds(30))  // the whole call, including retries
    .retryPolicy(.standard(maxRetries: 3))
    .circuitBreaker(breaker)
    .build()

// Override for a single request.
let report = try await client.get("https://api.example.com/report")
    .attemptTimeout(.seconds(60))  // each attempt
    .retry(.disabled)
    .send()
```

### Caching

```swift
let cache = HTTPCache(
    storage: MemoryCacheStorage(maxBytes: 20 * 1024 * 1024),
    defaultTTL: .minutes(1),  // for responses without caching headers
    maxStaleOnError: .hours(24)  // when offline, serve data up to a day old
)
let client = NetSkeinClient.builder().cache(cache).build()

let profile = try await client.get("https://api.example.com/me").send()
print(profile.headers.first(name: "Cache-Status") ?? "")  // "NetSkein; hit" when served from the cache

// Cache an endpoint for an hour, even if the server says not to.
let countries = try await client.get("https://api.example.com/countries")
    .cachePolicy(.fresh(for: .hours(1)))
    .send()

// On logout
await cache.removeAll()
```

To keep responses across app restarts, store them on disk:

```swift
let directory = FileManager.default
    .urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("netskein")

let cache = HTTPCache(
    storage: try DiskCacheStorage(directory: directory.path, maxBytes: 50 * 1024 * 1024)
)
```

Only `send()` uses the cache; `stream()`, `lines()` and `download(toFileAtPath:)` always go to the network.

### Middleware

```swift
let client = NetSkeinClient.builder()
    .using { request, _, next in
        var request = request
        request.headers.replaceOrAdd(name: "Authorization", value: "Bearer <token>")
        return try await next(request)
    }
    .using(CurlLoggingMiddleware(format: .multiline))
    .build()
```

For reusable middleware, conform a type to `HTTPMiddleware`.

### Testing

```swift
import NetSkein
import NetSkeinTesting
import Testing

@Test
func loadsTheProfile() async throws {
    let client = NetSkeinClient.testing()
        .addStub(
            try HTTPStub.get("https://api.example.com/me").json(Profile(id: 1, username: "ada"))
        )
        .build()

    let profile = try await client.get("https://api.example.com/me").send().json(Profile.self)

    #expect(profile.username == "ada")
    #expect(client.mock?.requests.count == 1)
}
```

## Examples

The [`Examples`](Examples) package has small runnable programs. Run one with `swift run <name>` from the `Examples` directory.

| Example                                                                            | Shows                                         |
| ---------------------------------------------------------------------------------- | --------------------------------------------- |
| [`GetJSON`](Examples/GetJSON/GetJSON.swift)                                        | Decoding a JSON response                      |
| [`GetHTML`](Examples/GetHTML/GetHTML.swift)                                        | Reading a response as text, with a size limit |
| [`StreamingByteCounter`](Examples/StreamingByteCounter/StreamingByteCounter.swift) | Streaming a response with progress            |
| [`CurlLogging`](Examples/CurlLogging/CurlLogging.swift)                            | Middleware and `curl` logging                 |
| [`HTTPCaching`](Examples/HTTPCaching/HTTPCaching.swift)                            | A guided tour of the HTTP cache               |

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) to set up your environment, and the [AI Policy](AI_POLICY.md) if you use AI tools.

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or <https://www.apache.org/licenses/LICENSE-2.0>)
- MIT License ([LICENSE-MIT](LICENSE-MIT) or <https://opensource.org/licenses/MIT>)

at your option.

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in NetSkein by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.
