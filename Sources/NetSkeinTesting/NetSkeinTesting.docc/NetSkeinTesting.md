# ``NetSkeinTesting``

Test code that uses NetSkein without a network: stub responses, check what was sent, and control time for the HTTP cache.

## Overview

`NetSkeinTesting` builds a `NetSkeinClient` whose requests never leave the process. Each request is answered by an ``HTTPStub`` you register, through a ``MockHTTPClient`` that stands in for the network. Everything else (middleware, retries, cookies, the cache, logging and tracing) runs exactly as in production, so your tests exercise the same code paths your app does.

Add the library to your test target only:

```swift
.testTarget(
    name: "MyAppTests",
    dependencies: [
        .product(name: "NetSkeinTesting", package: "netskein"),
    ]
)
```

A test builds a client with stubs, uses it like any other client, and checks the results:

```swift
import NIOCore
import NetSkein
import NetSkeinTesting
import Testing

struct Profile: Decodable {
    let name: String
}

@Test func loadsTheProfile() async throws {
    let client = NetSkeinClient.testing()
        .addStub(
            HTTPStub(
                method: .GET,
                url: "https://api.example.com/me",
                outcome: .response(status: .ok, headers: [:], body: ByteBuffer(string: #"{"name":"Ada"}"#))
            )
        )
        .build()

    let profile = try await client.get("https://api.example.com/me").send().json(Profile.self)

    #expect(profile.name == "Ada")
    #expect(client.mock?.requests.count == 1)
}
```

Pass the client into the code under test the same way your app passes its production client. Because both are a `NetSkeinClient`, the code under test does not need to know it is being tested.

## Topics

### Building a Test Client

- ``NetSkein/NetSkeinClient/testing()``
- ``TestClientBuilder``

### Stubbing Responses

- ``HTTPStub``
- ``MockHTTPClient``

### Checking What Was Sent

- ``NetSkein/NetSkeinClient/mock``
- ``MockHTTPClient/requests``

### Testing the Cache

- <doc:TestingTheCache>
- ``TestClock``
- ``NetSkein/HTTPCache/testing(clock:storage:maxEntryBytes:defaultTTL:maxStaleOnError:defaultPolicy:)``

### Testing Middleware

- ``NetSkein/MiddlewareContext/testing(attempt:requestID:logger:body:)``
