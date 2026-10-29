import AsyncHTTPClient

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Sends the jar's cookies for the request's host and stores the cookies the response sets.
///
/// The client adds it ahead of every other middleware when a ``CookieJar`` is configured, so
/// later middleware, such as ``CurlLoggingMiddleware``, sees the `Cookie` header.
struct CookieMiddleware: HTTPMiddleware {
    let jar: CookieJar

    func intercept(
        _ request: RequestHead,
        context: MiddlewareContext,
        next: Next
    ) async throws -> HTTPClientResponse {
        guard let host = URL(string: request.url)?.host else {
            return try await next(request)
        }

        var request = request
        if let cookieValue = jar.cookieHeader(for: host) {
            request.headers.replaceOrAdd(name: "Cookie", value: cookieValue)
        }

        let response = try await next(request)
        store(response.headers["Set-Cookie"], host: host)
        return response
    }

    private func store(_ cookieHeaders: [String], host: String) {
        for cookie in cookieHeaders {
            let components = cookie.components(separatedBy: ";")
            guard let parts = components.first?.components(separatedBy: "="), parts.count == 2
            else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            jar.setCookie(host: host, name: name, value: value)
        }
    }
}
