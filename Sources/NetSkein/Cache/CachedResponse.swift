import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

/// A response kept by an ``HTTPCache``, with what the cache needs to judge whether it can
/// still be used.
public struct CachedResponse: Sendable {
    public let status: HTTPResponseStatus

    /// The response's headers, without the ones a cache must not store, such as `Set-Cookie`.
    public let headers: HTTPHeaders

    public let body: ByteBuffer

    /// The request headers named by the response's `Vary` header, as they were sent.
    public let varyingRequestHeaders: HTTPHeaders

    /// When the request that produced this response was sent.
    public let requestTime: Date

    /// When the response was received.
    public let responseTime: Date

    /// Whether the response was stored for ``CachePolicy/fresh(for:)``, ignoring the server's
    /// caching headers. Such entries are only used by requests with the same policy.
    public let isForced: Bool

    /// How old the response already was when it was received (RFC 9111 §4.2.3). It only depends
    /// on the stored headers and times, so it is worked out once.
    private let initialAge: TimeInterval

    /// The lifetime `Expires` gives, measured from the response's `Date`: `nil` without
    /// `Expires`, and `0` for an invalid one, which means already expired (RFC 9111 §5.3).
    private let expiresLifetime: TimeInterval?

    public init(
        status: HTTPResponseStatus,
        headers: HTTPHeaders,
        body: ByteBuffer,
        varyingRequestHeaders: HTTPHeaders,
        requestTime: Date,
        responseTime: Date,
        isForced: Bool
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.varyingRequestHeaders = varyingRequestHeaders
        self.requestTime = requestTime
        self.responseTime = responseTime
        self.isForced = isForced

        // Parsed here rather than on every lookup: HTTP dates are the costly part of freshness
        let date = headers.first(name: "Date").flatMap(HTTPDate.parse) ?? responseTime
        let ageValue = headers.first(name: "Age").flatMap(Int.init).map { max(0, $0) } ?? 0

        let apparentAge = max(0, responseTime.timeIntervalSince(date))
        let responseDelay = responseTime.timeIntervalSince(requestTime)
        initialAge = max(apparentAge, TimeInterval(ageValue) + responseDelay)

        expiresLifetime = headers.first(name: "Expires")
            .map { expires in
                HTTPDate.parse(expires).map { $0.timeIntervalSince(date) } ?? 0
            }
    }
}

// MARK: - Age and Freshness

extension CachedResponse {
    var cacheControl: CacheControl { CacheControl(headers) }

    /// How old the response is at `now`, in seconds (RFC 9111 §4.2.3).
    func age(at now: Date) -> TimeInterval {
        initialAge + now.timeIntervalSince(responseTime)
    }

    /// How long the response stays fresh, in seconds (RFC 9111 §4.2.1).
    ///
    /// `max-age` wins over `Expires`. An invalid `Expires` means already expired. Without
    /// either, `defaultTTL` applies to responses that are cacheable by default.
    func freshnessLifetime(defaultTTL: TimeAmount?) -> TimeInterval {
        let cacheControl = cacheControl

        if let maxAge = cacheControl.seconds("max-age") {
            return TimeInterval(maxAge)
        }

        if let expiresLifetime {
            return expiresLifetime
        }

        guard
            let defaultTTL,
            status.isHeuristicallyCacheable || cacheControl.contains("public")
        else { return 0 }

        return defaultTTL.seconds
    }
}

// MARK: - Vary

extension CachedResponse {
    /// The request header names listed by the response's `Vary` header, lowercased.
    var varyingHeaderNames: [String] {
        Self.varyingHeaderNames(of: headers)
    }

    static func varyingHeaderNames(of headers: HTTPHeaders) -> [String] {
        headers["Vary"]
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Whether a request with `requestHeaders` may use this response (RFC 9111 §4.1).
    /// `Vary: *` never matches.
    func matches(_ requestHeaders: HTTPHeaders) -> Bool {
        varyingHeaderNames.allSatisfy { name in
            name != "*"
                && Self.value(of: name, in: requestHeaders)
                    == Self.value(of: name, in: varyingRequestHeaders)
        }
    }

    static func value(of name: String, in headers: HTTPHeaders) -> String {
        headers[name].joined(separator: ", ")
    }
}

// MARK: - Serving

extension CachedResponse {
    /// The response handed to the caller, with `Age` and `Cache-Status` set (RFC 9111 §5.1).
    func served(at now: Date, cacheStatus: String) -> HTTPClientResponse {
        var headers = headers
        let age = min(max(0, Int(age(at: now))), CacheControl.maxDeltaSeconds)
        headers.replaceOrAdd(name: "Age", value: "\(age)")
        headers.add(name: "Cache-Status", value: cacheStatus)
        return HTTPClientResponse(status: status, headers: headers, body: .bytes(body))
    }

    /// The response as confirmed by a `304 Not Modified`: its headers updated with those of the
    /// `304` (RFC 9111 §3.2), except the ones that describe the stored body or must not be stored,
    /// and its age restarted at `responseTime`.
    func refreshed(
        with notModified: HTTPHeaders,
        requestTime: Date,
        responseTime: Date
    ) -> CachedResponse {
        var headers = headers

        // `Age` and `Date` described the old response. Keeping them would make the confirmed copy
        // look as old as before. Without new ones, `Date` becomes the time the 304 arrived
        headers.remove(name: "Age")
        headers.remove(name: "Date")

        let updated = HTTPHeaders.storable(notModified, decompressedBodyLength: nil)

        for name in Set(updated.map { $0.name.lowercased() })
        where name != "content-length" && name != "content-encoding" {
            headers.remove(name: name)
            for value in updated[name] {
                headers.add(name: name, value: value)
            }
        }
        headers.addDateIfMissing(received: responseTime)

        return CachedResponse(
            status: status,
            headers: headers,
            body: body,
            varyingRequestHeaders: varyingRequestHeaders,
            requestTime: requestTime,
            responseTime: responseTime,
            isForced: isForced
        )
    }
}

// MARK: - Helpers

extension HTTPHeaders {
    /// Hop-by-hop fields, which a cache must not store (RFC 9111 §3.1).
    private static let hopByHop: Set<String> = [
        "connection",
        "keep-alive",
        "proxy-connection",
        "te",
        "transfer-encoding",
        "upgrade",
    ]

    /// `headers` without the fields a cache must not store, and without `Set-Cookie`, which
    /// would otherwise be replayed into the cookie jar on every hit. When the transport
    /// decompressed the body, `decompressedBodyLength` is its length, and `Content-Encoding` and
    /// `Content-Length` are corrected to match it.
    static func storable(_ headers: HTTPHeaders, decompressedBodyLength: Int?) -> HTTPHeaders {
        let connectionFields = headers["Connection"]
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }

        let excluded = hopByHop.union(connectionFields).union(["set-cookie", "cache-status"])

        var stored = HTTPHeaders(
            headers.filter { !excluded.contains($0.name.lowercased()) }
                .map { ($0.name, $0.value) }
        )

        if let decompressedBodyLength, stored.contains(name: "Content-Encoding") {
            stored.remove(name: "Content-Encoding")
            stored.replaceOrAdd(name: "Content-Length", value: "\(decompressedBodyLength)")
        }

        return stored
    }
}

extension HTTPResponseStatus {
    /// Status codes a cache may reuse without explicit freshness (RFC 9110 §15.1), except
    /// `206`, which this cache never stores.
    var isHeuristicallyCacheable: Bool {
        [200, 203, 204, 300, 301, 308, 404, 405, 410, 414, 501].contains(code)
    }
}

extension TimeAmount {
    var seconds: TimeInterval { TimeInterval(nanoseconds) / Nanoseconds.toSeconds }
}
