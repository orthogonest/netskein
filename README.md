# NetSkein

A high-performance, asynchronous HTTP client library for Swift, engineered from the ground up to deliver world-class ergonomics, compile-time safety, and data-race-free networking loops explicitly tailored for **Swift 6 Strict Concurrency**.

Built natively on top of **SwiftNIO** and `async-http-client`, NetSkein provides an elegant, fluent syntax builder interface that abstracts away low-level socket management while maintaining throughput efficiency.

> **Why the name Skein?**
>
> The word _Skein_ holds a double meaning that perfectly embodies this library:
>
> 1. It represents a beautifully coiled, orderly bundle of threads. Mirroring how NetSkein orchestrates complex asynchronous network streams.
> 2. It describes a V-shaped flock of birds in flight. Since **Swift** is named after a bird, _NetSkein_ symbolizes a highly coordinated, aerodynamically efficient flock of network operations flying together at maximum speed.

## Features Matrix

### 1. Core Request & Response

- **Fluent Method Chaining:** Declarative API pattern for structuring client engines and requests (`.get()`, `.post()`, `.header()`).
- **Query Parameter Serialization:** Effortlessly serialize dynamic key-value collections (`[String: String]`) straight into URL components.
- **Arbitrary Headers:** Dynamically add, modify, or swap outbound HTTP header matrices.
- **Idempotent Extractors:** Extract response payloads multiple times safely (e.g., logging text frames before mapping JSON structures) using non-mutating `ByteBuffer` offset inspectors:
  - `.text()` — Extracts payload into clear Swift Strings.
  - `.bytes()` — Retrieves raw `ByteBuffer` allocations.
  - `.json(Type.self)` — Type-safe, automatic `Decodable` object mapping.
- **Error for Status:** Expressive status code validation boundary mapping via `.errorForStatus()`, throwing strongly-typed errors for `4xx` and `5xx` server behaviors.

### 2. Runtime & Connection Performance

- **Built-in Connection Pooling:** Automatically reuse open TCP connections (`Keep-Alive`) via SwiftNIO infrastructure to eliminate handshake latency.
- **Non-Blocking Asynchronous Engine:** Fully driven by Swift's `async-http-client` core, guaranteeing high-throughput I/O loops without wasting hardware threads.
- **Granular Configurable Timeouts:** Express precision controls over `connectTimeout` (TCP handshakes) and `readTimeout` limits inside the client builder.
- **Corporate Proxy Injections:** Native support for routing traffic smoothly through manual or system-level network HTTP/HTTPS proxies.

### 3. Session Security & Cookie Hardening

- **Automatic Redirect Enforcements:** Secure redirect policy behaviors (follow, custom limit caps, or strictly turned off).
- **Stateful Cookie Store Integration:** Dynamic `NetSkeinCookieJar` encapsulated under a cross-platform custom `NIOLock` layer to safely intercept and inject `Set-Cookie` and `Cookie` headers across concurrent operations.
- **Native TLS Backends:** Fully managed TLS handshakes using system-level primitives (SecureTransport on macOS/iOS, OpenSSL on Linux).
- **Defensive Certification Controls:** Toggle validations for local testing sandboxes (`acceptInvalidCertificates`) or inject trusted self-signed root certificate anchors.

### 4. High-Performance Payload Handling

- **Thread-Safe Multipart Forms:** Package compound inputs mixing scalar fields and raw binary buffers using `NetSkeinMultipartForm.builder`. Uses a _Zero-Reallocation Dynamic Size Estimator_ (`estimatedLength`) to achieve zero-copy stream uploads.
- **URL-Encoded Forms:** Expressive `.form([String: String])` inputs mapping standard web configurations with automated percent encoding layouts.
- **True Dual-Direction Streaming (Anti-OOM):**
  - **Outbound Streaming:** Stream massive local disk files cleanly over network sockets via `.stream(fileAtPath:)` under an isolated `@Sendable` recursion flow.
  - **Inbound Streaming:** Pipe response downloads directly into disk storage via `.download(toFileAtPath:)` using dynamic `HTTPResponseHead` mapping—retaining cookie and log continuity with a flat, constant RAM profile.
- **Secure-by-Default Compression:** Automatic background decompression for `GZIP` and `Deflate` payloads protected by an absolute memory gate threshold (default: 10 MB) to neutralize malicious Zip Bomb exploits natively.

### 5. Observability & Tracing Telemetry

- **Distributed Tracing Synchronization:** NetSkein functions as a first-class citizen inside microservice grids. Every request generates a unique correlation token injected into the outbound `"X-Request-ID"` HTTP header and evaluates incoming response overrides to map trace flows globally.
- **`swift-log` Integration:** Telemetry logs map out lifetimes, processing durations, and failure footprints through lightweight, non-blocking asynchronous console tracking.
- **Type-Safe Error Localizations:** Custom error types (`NetSkeinError`) conformed fully to `LocalizedError`, `Equatable`, and `Hashable`, providing clean diagnostic strings (`errorDescription` and `failureReason`) for production telemetry dashboards.

## Installation

Add NetSkein to your `Package.swift` manifest files:

```swift
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MyApp",
    dependencies: [
        .package(url: "https://github.com/orthogonest/netskein", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: [
                .product(name: "NetSkein", package: "netskein"),
            ]
        ),
    ]
)
```

## Quick Start & Usage Examples

### 1. Basic In-Memory Requests (JSON Decoding)

```swift
import Foundation
import NetSkein

struct UserProfile: Decodable {
    let id: Int
    let username: String
    let email: String
}

/// Instantiate client container utilizing production default settings
let client = NetSkeinClient.builder()
    .connectTimeout(.seconds(5))
    .build()

do {
    let profile = try await client.get("https://example.com")
        .header("Authorization", "Bearer your_token_here")
        .query(["version": "2.0"])
        .send()
        .errorForStatus() // Validate 2xx boundaries
        .json(UserProfile.self) // Decode safely and non-destructively

    print("Welcome back, \(profile.username)!")
} catch {
    print("API Error: \(error.localizedDescription)")
}
```

### 2. High-Performance Symmetrical Streaming (Zero OOM Spikes)

#### Outbound Upload Stream:

```swift
/// Stream a 2 GB video asset from the local disk directly over the network socket
let uploadResponse = try await client.post("https://example.com")
    .stream(fileAtPath: "/Users/developer/Movies/holiday_4k.mp4")
    .send()
```

#### Inbound Download Stream:

```swift
// Pipe a 5 GB remote software installer installer straight into disk storage
try await client.get("https://example.com")
    .download(toFileAtPath: "/Users/developer/Downloads/target_installer.dmg")
```

### 3. Thread-Safe Multipart Form Assembly

```swift
let formPayload = NetSkeinMultipartForm.builder
    .text(name: "caption", value: "Summer Vacation 2026")
    .file(name: "photo", filename: "beach.jpg", contentType: "image/jpeg", body: rawByteBuffer)
    .build() // Locked into a pure immutable, Sendable struct payload container

let response = try await client.post("https://example.com")
    .multipart(formPayload)
    .send()
```

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or http://apache.org/licenses/LICENSE-2.0)
- MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
