# ``NetSkein``

An async HTTP client for Swift 6, with a fluent request builder, typed errors, retries, caching and middleware.

## Overview

NetSkein is built on [AsyncHTTPClient](https://github.com/swift-server/async-http-client) and compiles cleanly under Swift 6 strict concurrency. You build a ``NetSkeinClient`` once, describe each request with a chain of method calls, and read the response as text, bytes or JSON:

```swift
import NetSkein

struct Profile: Decodable {
    let id: Int
    let username: String
}

let client = NetSkeinClient.builder()
    .connectTimeout(.seconds(5))
    .build()

let profile = try await client.get("https://api.example.com/me")
    .header("Authorization", "Bearer <token>")
    .send()
    .validate()
    .json(Profile.self)

try await client.shutdown()
```

Every request throws a single error type, ``NetSkeinError``, so a `catch` block can tell a timeout from a bad status without casting.

To test code that uses NetSkein without a network, add the `NetSkeinTesting` library to your test target.

## Topics

### Essentials

- ``NetSkeinClient``
- ``NetSkeinClientBuilder``
- ``NetSkeinRequest``
- ``NetSkeinResponse``
- ``NetSkeinError``

### Request Bodies

- ``MultipartForm``
- ``PathSegment``
- ``PercentEncoder``
- ``BodyState``
- ``BodyForbidden``
- ``BodyAllowed``
- ``BodyAttached``

### Streaming and File Transfers

- ``NetSkeinStream``
- ``NetSkeinLines``
- ``ChunkHandler``
- ``UploadProgress``
- ``DownloadProgress``
- ``DownloadResumption``

### Retries and Circuit Breaking

- ``RetryPolicy``
- ``RetryContext``
- ``BackoffStrategy``
- ``CircuitBreaker``

### Caching

- ``HTTPCache``
- ``CachePolicy``
- ``CachedResponse``
- ``CacheStorage``
- ``MemoryCacheStorage``
- ``DiskCacheStorage``

### Middleware

- ``HTTPMiddleware``
- ``MiddlewareScope``
- ``MiddlewareContext``
- ``RequestHead``
- ``RequestBodyDescription``
- ``CurlLoggingMiddleware``

### Connections and Security

- ``HTTPVersionPolicy``
- ``RedirectPolicy``
- ``Proxy``
- ``CookieJar``

### Transport

- ``HTTPTransport``
