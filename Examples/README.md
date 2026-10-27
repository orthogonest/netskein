# Examples

This folder includes a couple of practical, executable examples for the **NetSkein** asynchronous networking framework.
You can run them by opening the root `Package.swift` file through Xcode. In Xcode, you can then select the scheme for the specific example you want to run (e.g., `GetHTML`).

Alternatively, you can run the examples directly from your terminal by executing the following command inside this folder:

```bash
swift run GetHTML
```

To run other examples, simply replace `GetHTML` with the name of the example executable you want to run.

---

## [GetHTML](./GetHTML/GetHTML.swift)

This example sends an HTTP GET request to `https://apple.com/` using the fluent chain builder. It prints the HTTP response metadata and safely extracts the plain-text HTML body using the synchronized `.text()` helper function after the framework automatically accumulates the response network sequence.

## [GetJSON](./GetJSON/GetJSON.swift)

This example sends an HTTP GET request to `https://xkcd.com/info.0.json`. It leverages NetSkein's built-in type-safe response extensions to automatically decode the incoming binary memory buffer into a Swift `Decodable` struct using a `JSONDecoder`, followed by a comprehensive data `dump`.

## [StreamingByteCounter](./StreamingByteCounter/StreamingByteCounter.swift)

This example fires an HTTP GET request to `https://apple.com/` and streams the inbound response segments piece-by-piece via a safe, modern asynchronous closure.

As raw `ByteBuffer` fragments slide through the network pipe, it calculates real-time progress indicators on the fly (leveraging the server's `Content-Length` metadata). Because fragments are handled instantly inside the live closure loop, the framework maintains strict backpressure and avoids inflating the application's overall in-memory RAM usage.

## [CurlLogging](./CurlLogging/CurlLogging.swift)

This example registers two middlewares on the client: a closure that adds an `Authorization` header, followed by `CurlLoggingMiddleware`. It then sends a JSON `POST` to `https://httpbin.org/post`.

Because middleware runs in the order it is added, the curl logger sees the request after the credential was attached and prints it as a ready-to-paste `curl` command with the `Authorization` value redacted. The logger is set to `.debug`, the level `CurlLoggingMiddleware` uses by default.
