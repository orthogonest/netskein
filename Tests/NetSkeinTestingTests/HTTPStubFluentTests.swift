import AsyncHTTPClient
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NetSkein
import NetSkeinTesting
import Testing

/// The fluent `HTTPStub` API, used through a test client the way an app's tests would.
struct HTTPStubFluentTests {
    let url = "https://api.example.com/items"

    struct Item: Codable, Equatable {
        let name: String
    }

    struct Offline: Error {}

    func send(_ method: HTTPMethod = .GET, to stub: HTTPStub) async throws -> NetSkeinResponse {
        let client = NetSkeinClient.testing().retryPolicy(.disabled).addStub(stub).build()
        return try await client.request(method, url: url).send()
    }
}

// MARK: - Starting a Stub

extension HTTPStubFluentTests {
    @Test(
        "HTTPStubFluentTests: each starting point answers its method with 200 and no body",
        arguments: [
            (HTTPStub.get("https://api.example.com/items"), HTTPMethod.GET),
            (.post("https://api.example.com/items"), .POST),
            (.put("https://api.example.com/items"), .PUT),
            (.patch("https://api.example.com/items"), .PATCH),
            (.delete("https://api.example.com/items"), .DELETE),
            (.request(.HEAD, url: "https://api.example.com/items"), .HEAD),
            (.request(.OPTIONS, matching: { $0.hasSuffix("/items") }), .OPTIONS),
        ]
    )
    func testStartingPoints(stub: HTTPStub, method: HTTPMethod) async throws {
        let response = try await send(method, to: stub)

        #expect(stub.method == method)
        #expect(stub.urlMatcher(url))
        #expect(!stub.urlMatcher(url + "/other"))
        #expect(response.status == .ok)
        #expect(response.bytes() == nil)
    }
}

// MARK: - Describing the Response

extension HTTPStubFluentTests {
    @Test("HTTPStubFluentTests: status, headers and body describe the response")
    func testResponse() async throws {
        let response = try await send(
            to: .get(url)
                .status(.accepted)
                .header("X-Old", "1")
                .headers(["X-Replaced": "1"])
                .header("X-Trace", "a")
                .header("X-Trace", "b")
                .body(ByteBuffer(string: "raw"))
        )

        #expect(response.status == .accepted)
        #expect(!response.headers.contains(name: "X-Old"))
        #expect(response.headers.first(name: "X-Replaced") == "1")
        #expect(response.headers["X-Trace"] == ["b"])
        #expect(response.text() == "raw")
    }

    @Test("HTTPStubFluentTests: text and json set the body and its Content-Type")
    func testTextAndJSON() async throws {
        let text = try await send(to: .get(url).text("hello"))
        let json = try await send(to: .get(url).json(Item(name: "Ada")))

        #expect(text.text() == "hello")
        #expect(text.headers.first(name: "Content-Type") == "text/plain; charset=utf-8")
        #expect(try json.json(Item.self) == Item(name: "Ada"))
        #expect(json.headers.first(name: "Content-Type") == "application/json")
    }

    @Test("HTTPStubFluentTests: json throws when the value cannot be encoded")
    func testJSONEncodingFailure() {
        #expect(throws: (any Error).self) {
            _ = try HTTPStub.get(url).json(Double.nan)
        }
    }

    @Test("HTTPStubFluentTests: a failing stub fails, whatever is set before or after")
    func testFail() async throws {
        let stubs = [
            HTTPStub.get(url).fail(with: Offline()),
            HTTPStub.get(url).text("ignored").fail(with: Offline()),
            HTTPStub.get(url).fail(with: Offline()).status(.ok).text("ignored"),
        ]

        for stub in stubs {
            await #expect(throws: NetSkeinError.self) {
                _ = try await send(to: stub)
            }
        }
    }
}

// MARK: - Timing and Checks

extension HTTPStubFluentTests {
    @Test("HTTPStubFluentTests: delay and validate are applied to matching requests")
    func testDelayAndValidate() async throws {
        let checked = NIOLockedValueBox(false)
        let stub = HTTPStub.get(url)
            .delay(.milliseconds(1))
            .validate { request in
                #expect(request.url == "https://api.example.com/items")
                checked.withLockedValue { $0 = true }
            }

        _ = try await send(to: stub)

        #expect(stub.delay == .milliseconds(1))
        #expect(checked.withLockedValue { $0 })
    }
}
