import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

/// Answers requests from an ``HTTPCache`` and stores the responses it may (RFC 9111).
///
/// The client places it last, next to the transport, so it sees each request exactly as it is
/// sent: `Vary` is matched against the headers other middleware added.
struct CacheMiddleware {
    let cache: HTTPCache

    let policy: CachePolicy

    /// `false` for `stream` and `download`, which read the body as it arrives: their requests
    /// never use or store a cached response, but an unsafe one still invalidates.
    let usesStoredResponses: Bool

    /// Whether the transport decompresses bodies but leaves `Content-Encoding` in place.
    let transportDecompresses: Bool

    /// The request's body limit, applied when the body is collected for storing.
    let maxResponseBytes: Int
}

extension CacheMiddleware: HTTPMiddleware {
    func intercept(
        _ request: RequestHead,
        context: MiddlewareContext,
        next: Next
    ) async throws -> HTTPClientResponse {
        guard let key = HTTPCache.key(for: request.url) else {
            return try await bypass(request, next: next, reason: "fwd=bypass")
        }

        guard request.method.isSafe else {
            let response = try await bypass(request, next: next, reason: "fwd=method")
            // A non-error response to an unsafe method invalidates its URL (§4.4)
            if (200..<400).contains(response.status.code) {
                await cache.storage.remove(url: key)
            }
            return response
        }

        guard request.method == .GET else {
            return try await bypass(request, next: next, reason: "fwd=method")
        }

        guard
            usesStoredResponses,
            context.body == .none,
            !request.headers.hasConditionalFields
        else {
            return try await bypass(request, next: next, reason: "fwd=bypass")
        }

        let exchange = CacheExchange(
            cache: cache,
            request: request,
            key: key,
            directives: RequestDirectives(request.headers, policy: policy),
            transportDecompresses: transportDecompresses,
            maxResponseBytes: maxResponseBytes
        )

        return try await exchange.run(next)
    }
}

extension CacheMiddleware {
    /// Sends `request` without using the cache, saying why in `Cache-Status` (RFC 9211 §2.2):
    /// `fwd=method` for methods whose responses are not cached, `fwd=bypass` for requests the
    /// cache does not handle.
    private func bypass(
        _ request: RequestHead,
        next: Next,
        reason: String
    ) async throws -> HTTPClientResponse {
        var response = try await next(request)
        response.headers.add(name: "Cache-Status", value: .cacheStatus(reason))
        return response
    }
}

// MARK: - Exchange

/// One cacheable request: finds a stored response, then reuses it, revalidates it, or goes to
/// the network and stores the result.
private struct CacheExchange {
    let cache: HTTPCache
    let request: RequestHead
    let key: String
    let directives: RequestDirectives
    let transportDecompresses: Bool
    let maxResponseBytes: Int
}

extension CacheExchange {
    func run(_ next: HTTPMiddleware.Next) async throws -> HTTPClientResponse {
        let requestTime = cache.now()
        let entries = await cache.storage.entries(for: key)
        // Entries are stored oldest first, so the last match is the most recent
        let candidate = entries.last { directives.accepts($0) && $0.matches(request.headers) }

        guard let entry = candidate else {
            if directives.onlyIfCached { return .gatewayTimeout }
            let response = try await next(request)
            // Entries this request may not use, such as forced ones, do not make it a Vary miss
            let reason =
                entries.contains(where: directives.accepts)
                ? "fwd=vary-miss"
                : "fwd=uri-miss"
            return try await store(response, sentAt: requestTime, among: entries, reason: reason)
        }

        if let reused = reuse(entry, at: requestTime) { return reused }
        if directives.onlyIfCached { return .gatewayTimeout }

        return try await revalidate(entry, among: entries, sentAt: requestTime, next: next)
    }

    /// The stored response, when it can be used without asking the server (§4.2).
    private func reuse(_ entry: CachedResponse, at now: Date) -> HTTPClientResponse? {
        let rules = ResponseRules(entry, directives: directives)
        guard !rules.requiresValidation, !directives.noCache else { return nil }

        let age = entry.age(at: now)

        if let maxAge = directives.maxAge, age > TimeInterval(maxAge) {
            return nil
        }

        let lifetime = lifetime(of: entry)

        if let minFresh = directives.minFresh, lifetime - age < TimeInterval(minFresh) {
            return nil
        }

        if age >= lifetime {
            // Stale: only when the request accepts it and the response does not forbid it
            guard
                rules.allowsStale,
                let maxStale = directives.maxStale,
                age - lifetime <= TimeInterval(maxStale)
            else { return nil }
        }

        return entry.served(at: now, cacheStatus: .cacheStatus("hit"))
    }

    /// How long `entry` stays fresh for this request: the forced TTL, or the server's (§4.2.1).
    private func lifetime(of entry: CachedResponse) -> TimeInterval {
        directives.forcedLifetime?.seconds ?? entry.freshnessLifetime(defaultTTL: cache.defaultTTL)
    }

    /// Asks the server whether the stored response is still valid (§4.3).
    private func revalidate(
        _ entry: CachedResponse,
        among entries: [CachedResponse],
        sentAt requestTime: Date,
        next: HTTPMiddleware.Next
    ) async throws -> HTTPClientResponse {
        let age = entry.age(at: requestTime)
        let lifetime = lifetime(of: entry)
        let rules = ResponseRules(entry, directives: directives)

        // A fresh copy only goes to the server because the request asked (RFC 9211 §2.2)
        let isFresh = !rules.requiresValidation && age < lifetime
        let reason = isFresh ? "fwd=request" : "fwd=stale"

        let response: HTTPClientResponse
        do {
            response = try await next(conditionalRequest(for: entry))
        } catch {
            if let stale = staleOnError(entry) { return stale }
            throw error
        }

        if response.status == .notModified {
            guard HTTPValidator(entry.headers).matches(HTTPValidator(response.headers)) else {
                // The 304 is for another representation: fetch this one in full. Middleware may call
                // `next` more than once. Here it is the transport, so this is a second request
                let full = try await next(request)
                let fullReason = "\(reason); fwd-status=\(full.status.code)"
                return try await store(
                    full,
                    sentAt: requestTime,
                    among: entries,
                    reason: fullReason
                )
            }

            let refreshed = entry.refreshed(
                with: response.headers,
                requestTime: requestTime,
                responseTime: cache.now()
            )

            var refreshedReason = "\(reason); fwd-status=304"
            if !directives.noStore {
                await cache.storage.store(storing(refreshed, among: entries), for: key)
                refreshedReason += "; stored"
            }

            return refreshed.served(
                at: cache.now(),
                cacheStatus: .cacheStatus(refreshedReason)
            )
        }

        if response.status.isServerFailure, let stale = staleOnError(entry) {
            // Read the unused body to the end so the connection can be reused instead of closed.
            // The limit avoids downloading a large error page for nothing
            _ = try? await response.body.collect(upTo: cache.maxEntryBytes)
            return stale
        }

        let fetchedReason = "\(reason); fwd-status=\(response.status.code)"
        return try await store(response, sentAt: requestTime, among: entries, reason: fetchedReason)
    }

    private func conditionalRequest(for entry: CachedResponse) -> RequestHead {
        var conditional = request
        for (name, value) in HTTPValidator(entry.headers).conditionalHeaders {
            conditional.headers.replaceOrAdd(name: name, value: value)
        }
        return conditional
    }

    /// The stored response, when the server failed and it is no more than `maxStaleOnError` past
    /// its expiry (RFC 5861 §4).
    private func staleOnError(_ entry: CachedResponse) -> HTTPClientResponse? {
        let rules = ResponseRules(entry, directives: directives)
        let now = cache.now()

        guard
            let limit = cache.maxStaleOnError,
            !Task.isCancelled,
            rules.allowsStale,
            !rules.requiresValidation,
            entry.age(at: now) - lifetime(of: entry) <= limit.seconds
        else { return nil }

        return entry.served(
            at: now,
            cacheStatus: .cacheStatus("fwd=stale; detail=error")
        )
    }
}

// MARK: - Storing

extension CacheExchange {
    /// Stores `response` when RFC 9111 allows it (§3), and returns it with its body intact.
    private func store(
        _ response: HTTPClientResponse,
        sentAt requestTime: Date,
        among entries: [CachedResponse],
        reason: String
    ) async throws -> HTTPClientResponse {
        var response = response
        let cacheStatus: String = .cacheStatus(reason)

        guard isStorable(response) else {
            response.headers.add(name: "Cache-Status", value: cacheStatus)
            return response
        }

        // Only send() reaches here, and it collects the whole body anyway, under the same limit
        let body: ByteBuffer
        do {
            body = try await response.body.collect(upTo: maxResponseBytes)
        } catch {
            throw NetSkeinError.custom(
                kind: .networkFailure,
                message: "Failed to collect response body sequence: \(error.localizedDescription)",
                underlyingError: error
            )
        }
        response.body = .bytes(body)

        guard body.readableBytes <= cache.maxEntryBytes else {
            response.headers.add(name: "Cache-Status", value: cacheStatus)
            return response
        }

        let responseTime = cache.now()
        var storedHeaders = HTTPHeaders.storable(
            response.headers,
            decompressedBodyLength: transportDecompresses ? body.readableBytes : nil
        )
        storedHeaders.addDateIfMissing(received: responseTime)

        let entry = CachedResponse(
            status: response.status,
            headers: storedHeaders,
            body: body,
            varyingRequestHeaders: varyingRequestHeaders(for: response.headers),
            requestTime: requestTime,
            responseTime: responseTime,
            isForced: directives.isForced
        )
        await cache.storage.store(storing(entry, among: entries), for: key)

        response.headers.add(name: "Cache-Status", value: "\(cacheStatus); stored")
        return response
    }

    private func isStorable(_ response: HTTPClientResponse) -> Bool {
        let code = response.status.code

        // A redirected response belongs to another URL, and partial content is not supported
        guard
            !directives.noStore,
            response.history.count <= 1,
            (200..<600).contains(code),
            code != 206,
            code != 304
        else { return false }

        if directives.isForced { return (200..<300).contains(code) }

        let cacheControl = CacheControl(response.headers)
        let varyingNames = CachedResponse.varyingHeaderNames(of: response.headers)

        // must-understand overrides no-store for status codes the cache understands (§5.2.2.3)
        guard
            !cacheControl.contains("no-store") || cacheControl.contains("must-understand"),
            !varyingNames.contains("*")
        else { return false }

        return cacheControl.contains("max-age")
            || response.headers.contains(name: "Expires")
            || cacheControl.contains("public")
            || cacheControl.contains("private")
            || response.status.isHeuristicallyCacheable
    }

    private func varyingRequestHeaders(for responseHeaders: HTTPHeaders) -> HTTPHeaders {
        var varying = HTTPHeaders()
        for name in CachedResponse.varyingHeaderNames(of: responseHeaders) {
            for value in request.headers[name] { varying.add(name: name, value: value) }
        }
        return varying
    }

    /// `entries` with `entry` in place of the variant the current request matches.
    private func storing(
        _ entry: CachedResponse,
        among entries: [CachedResponse]
    ) -> [CachedResponse] {
        entries.filter { !isSameVariant($0, as: entry) } + [entry]
    }

    /// Whether `stored` is the entry this request would use, of the same kind as `entry`: both
    /// forced or both not, since forced entries are kept apart from the rest.
    private func isSameVariant(_ stored: CachedResponse, as entry: CachedResponse) -> Bool {
        stored.isForced == entry.isForced && stored.matches(request.headers)
    }
}

// MARK: - Directives

/// The request's cache directives, combined with the request's ``CachePolicy`` (§5.2.1).
private struct RequestDirectives {
    var noStore: Bool
    var noCache: Bool
    var onlyIfCached: Bool
    var maxAge: Int?
    var maxStale: Int?
    var minFresh: Int?
    var forcedLifetime: TimeAmount?
    /// Whether responses stored with ``CachePolicy/fresh(for:)`` may answer this request.
    var includesForcedEntries = false

    init(_ headers: HTTPHeaders, policy: CachePolicy) {
        let cacheControl = CacheControl(headers)
        noStore = cacheControl.contains("no-store")
        // RFC 9111 §5.4 deprecates Pragma. Its no-cache is still honoured, as old clients and
        // proxies send it, but only without a Cache-Control, which takes precedence
        noCache =
            cacheControl.contains("no-cache")
            || (!headers.contains(name: "Cache-Control")
                && headers["Pragma"].contains { $0.lowercased().contains("no-cache") })
        onlyIfCached = cacheControl.contains("only-if-cached")
        maxAge = cacheControl.seconds("max-age")
        minFresh = cacheControl.seconds("min-fresh")
        // max-stale without a value accepts any staleness
        maxStale =
            cacheControl.hasArgument("max-stale")
            ? cacheControl.seconds("max-stale")
            : cacheControl.contains("max-stale") ? Int.max : nil

        switch policy {
        case .returnCacheElseLoad:
            maxStale = Int.max
            includesForcedEntries = true
        case .onlyIfCached:
            onlyIfCached = true
            maxStale = Int.max
            includesForcedEntries = true
        case let .fresh(ttl):
            forcedLifetime = ttl
        case .default, .reloadIgnoringCache, .noStore:
            // The latter two are sent as request headers, and read from them above
            break
        }
    }
}

extension RequestDirectives {
    var isForced: Bool { forcedLifetime != nil }

    /// Whether `entry` may answer this request: forced entries are kept apart from the rest,
    /// except for policies that accept anything stored.
    func accepts(_ entry: CachedResponse) -> Bool {
        isForced ? entry.isForced : !entry.isForced || includesForcedEntries
    }
}

/// What a stored response's own directives allow (§5.2.2). Forced entries ignore them.
private struct ResponseRules {
    /// `no-cache`: never reuse without asking the server.
    ///
    /// The qualified form, `no-cache="X-Token"`, only forbids reusing the named fields unchecked.
    /// It is treated as the unqualified one, as RFC 9111 §5.2.2.4 notes is common: hiding the
    /// fields on hits would leave them present on some responses and missing on others.
    let requiresValidation: Bool

    /// `must-revalidate` forbids serving the response once stale.
    let allowsStale: Bool

    init(_ entry: CachedResponse, directives: RequestDirectives) {
        guard !entry.isForced else {
            requiresValidation = false
            allowsStale = true
            return
        }
        let cacheControl = entry.cacheControl
        requiresValidation = cacheControl.contains("no-cache")
        allowsStale = !cacheControl.contains("must-revalidate")
    }
}

// MARK: - Helpers

extension HTTPMethod {
    /// Methods that do not change state on the server (RFC 9110 §9.2.1).
    fileprivate var isSafe: Bool {
        switch self {
        case .GET, .HEAD, .OPTIONS, .TRACE: true
        default: false
        }
    }
}

extension HTTPHeaders {
    /// Whether the request carries its own validators or range, which the cache must not
    /// answer on the caller's behalf.
    fileprivate var hasConditionalFields: Bool {
        [
            "If-None-Match",
            "If-Modified-Since",
            "If-Match",
            "If-Unmodified-Since",
            "If-Range",
            "Range",
        ]
        .contains { contains(name: $0) }
    }
}

extension HTTPClientResponse {
    /// The answer to `only-if-cached` when nothing usable is stored (§5.2.1.7).
    fileprivate static var gatewayTimeout: HTTPClientResponse {
        HTTPClientResponse(
            status: .gatewayTimeout,
            headers: ["Cache-Status": .cacheStatus("detail=only-if-cached")]
        )
    }
}

extension String {
    /// A `Cache-Status` member for this cache (RFC 9211).
    fileprivate static func cacheStatus(_ parameters: String) -> String {
        "NetSkein; \(parameters)"
    }
}
