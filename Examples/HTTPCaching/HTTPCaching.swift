import Foundation
import NetSkein

/// A guided tour of NetSkein's HTTP cache against httpbin.org.
///
/// Each step sends a few requests and prints what the cache did with them, read from the
/// `Cache-Status` header NetSkein adds to every response:
///
/// - `hit`: answered from the cache, without a network call
/// - `fwd=uri-miss`: nothing stored for this URL, so the request went to the network
/// - `fwd=vary-miss`: something is stored, but for different request headers
/// - `fwd=stale`: the stored response was too old, so the cache asked the server
/// - `fwd=request`: the request itself asked to go to the server
/// - `fwd-status=304`: the server confirmed the stored response is unchanged
/// - `stored`: the network response was kept for next time
@main
struct HTTPCaching {
    static func main() async throws {
        let cache = HTTPCache(storage: MemoryCacheStorage(maxBytes: 10 * 1024 * 1024))
        let client = NetSkeinClient.builder().cache(cache).build()

        do {
            try await freshness(client)
            try await validation(client)
            try await serverRestrictions(client)
            try await clientRequests(client)
            try await variants(client)
            try await invalidation(client)
            try await offline(client, cache: cache)
            try await forcedFreshness(client)
        } catch {
            print("request failed:", error)
        }

        // It is important to shutdown the client after all requests are done, even if one failed
        try await client.shutdown()
    }

    /// The server says how long a response stays fresh; until then the cache answers alone.
    static func freshness(_ client: NetSkeinClient) async throws {
        step(1, "Freshness: `Cache-Control: max-age=60` lets the cache answer for 60 seconds")
        let url = "https://httpbin.org/cache/60"

        show("first request ", try await client.get(url).send())
        try await Task.sleep(nanoseconds: 2_000_000_000)
        show("2 seconds later", try await client.get(url).send())
        note("The second response never touched the network. `Age` says how old the copy is.")
    }

    /// When a response has no freshness, the cache asks "has it changed?" instead of
    /// downloading it again.
    static func validation(_ client: NetSkeinClient) async throws {
        step(2, "Validation: an `ETag` lets the cache ask whether its copy is still current")
        let url = "https://httpbin.org/etag/v1"

        show("first request ", try await client.get(url).send())
        let revalidated = try await client.get(url).send()
        show("second request", revalidated)
        note(
            """
            The response has no `max-age`, so it is stale at once. The second request sent \
            `If-None-Match: v1`; the server answered `304 Not Modified` without a body, and the \
            cache returned its stored body as a 200 (\(revalidated.bytes()?.readableBytes ?? 0) bytes).
            """
        )
    }

    /// The server can forbid storing, or require checking before every reuse.
    static func serverRestrictions(_ client: NetSkeinClient) async throws {
        step(3, "Server restrictions: `no-store` means the response is never kept")
        let url = "https://httpbin.org/response-headers?Cache-Control=no-store"

        show("first request ", try await client.get(url).send())
        show("second request", try await client.get(url).send())
        note("Neither response says `stored`: both went to the network.")
    }

    /// The client can ask for the latest data, for example on pull-to-refresh.
    static func clientRequests(_ client: NetSkeinClient) async throws {
        step(
            4,
            "Client requests: `.reloadIgnoringCache` checks with the server despite a fresh copy"
        )
        let url = "https://httpbin.org/cache/60"

        show("normal request", try await client.get(url).send())
        show("pull-to-refresh", try await client.get(url).cachePolicy(.reloadIgnoringCache).send())
        note("The refresh sent `Cache-Control: no-cache` and stored the new response.")
    }

    /// One URL can have several versions, chosen by a request header the server names in `Vary`.
    static func variants(_ client: NetSkeinClient) async throws {
        step(5, "Variants: `Vary: Accept-Language` keeps one copy per language")
        let url =
            "https://httpbin.org/response-headers?Cache-Control=max-age%3D60&Vary=Accept-Language"

        show("English       ", try await client.get(url).header("Accept-Language", "en").send())
        show("French        ", try await client.get(url).header("Accept-Language", "fr").send())
        show("English again ", try await client.get(url).header("Accept-Language", "en").send())
        note("French was a `vary-miss`: the English copy could not answer a French request.")
    }

    /// A successful change to a URL throws its cached copies away.
    static func invalidation(_ client: NetSkeinClient) async throws {
        step(6, "Invalidation: a successful POST removes the cached GET for the same URL")
        let url = "https://httpbin.org/response-headers?Cache-Control=max-age%3D60"

        show("GET           ", try await client.get(url).send())
        show("GET again     ", try await client.get(url).send())
        _ = try await client.post(url).send()
        show("GET after POST", try await client.get(url).send())
        note("After the POST the copy was gone, so the last GET went to the network.")
    }

    /// An app can switch every request to cached data while it knows it is offline.
    static func offline(_ client: NetSkeinClient, cache: HTTPCache) async throws {
        step(7, "Offline mode: `defaultPolicy = .onlyIfCached` never uses the network")
        cache.defaultPolicy = .onlyIfCached

        show("cached URL    ", try await client.get("https://httpbin.org/cache/60").send())
        show("unknown URL   ", try await client.get("https://httpbin.org/uuid").send())
        note("Stored responses are served however old they are; anything else is a 504.")

        cache.defaultPolicy = .default
    }

    /// Some backends forbid caching everything; `.fresh(for:)` caches a response anyway.
    static func forcedFreshness(_ client: NetSkeinClient) async throws {
        step(8, "Forced freshness: `.fresh(for:)` caches reference data despite `no-store`")
        let url = "https://httpbin.org/response-headers?Cache-Control=no-store&X-Data=countries"

        show(
            "forced        ",
            try await client.get(url).cachePolicy(.fresh(for: .minutes(5))).send()
        )
        show(
            "forced again  ",
            try await client.get(url).cachePolicy(.fresh(for: .minutes(5))).send()
        )
        show("normal request", try await client.get(url).send())
        note(
            "Only requests asking for `.fresh(for:)` see the forced copy; a normal request does not."
        )
    }
}

// MARK: - Output

extension HTTPCaching {
    static func step(_ number: Int, _ title: String) {
        print("\n\(number). \(title)")
    }

    static func show(_ label: String, _ response: NetSkeinResponse) {
        // Other caches on the way, such as a CDN, may add their own Cache-Status entries
        let cacheStatus =
            response.headers["Cache-Status"]
            .flatMap { $0.split(separator: ",") }
            .last { $0.trimmingCharacters(in: .whitespaces).hasPrefix("NetSkein") }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? "-"
        let age = response.headers.first(name: "Age").map { "  Age: \($0)" } ?? ""
        let column = label.trimmingCharacters(in: .whitespaces)
            .padding(toLength: 16, withPad: " ", startingAt: 0)
        print("   \(column) \(response.status.code)  \(cacheStatus)\(age)")
    }

    static func note(_ text: String) {
        print("   → \(text)")
    }
}
