import NIOConcurrencyHelpers
import NIOHTTP1

/// Stores cookies by host, so a client sends them back on later requests.
///
/// Give a jar to ``NetSkeinClientBuilder/cookieJar(_:)``. The client then stores the cookies
/// each response sets with `Set-Cookie`, and sends the host's cookies in a `Cookie` header on
/// every request to that host.
///
/// The jar is kept simple. It keeps only each cookie's name and value, matched to the exact host
/// that set it, and ignores attributes such as `Domain`, `Path`, `Expires` and `Secure`. Cookies
/// last until you call ``clear()`` or the jar is released, and live only in memory.
///
/// The jar is safe to share between clients and tasks.
public final class CookieJar: Sendable {
    private let storage: NIOLockedValueBox<[String: [String: String]]>

    /// Creates an empty jar.
    public init() {
        storage = NIOLockedValueBox([:])
    }
}

extension CookieJar {
    /// Stores a cookie for `host`, replacing any cookie with the same name.
    ///
    /// Use it to send a cookie the server never set, such as a session token you got elsewhere.
    ///
    /// - Parameters:
    ///   - host: The host to send the cookie to, such as `api.example.com`. It must match the
    ///     request's host exactly.
    ///   - name: The cookie name.
    ///   - value: The cookie value.
    public func setCookie(host: String, name: String, value: String) {
        storage.withLockedValue { cookies in
            if cookies[host] == nil { cookies[host] = [:] }
            cookies[host]?[name] = value
        }
    }

    /// Returns the value of the `Cookie` header for `host`, such as `"id=42; theme=dark"`, or
    /// `nil` when the jar has no cookies for it.
    ///
    /// - Parameter host: The host the request goes to, such as `api.example.com`.
    /// - Returns: The `Cookie` header value, or `nil` when the jar has no cookies for `host`.
    public func cookieHeader(for host: String) -> String? {
        storage.withLockedValue { cookies in
            guard let hostCookies = cookies[host], !hostCookies.isEmpty else { return nil }
            return hostCookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        }
    }

    /// Removes every cookie from the jar, for all hosts.
    public func clear() {
        storage.withLockedValue { cookies in cookies.removeAll() }
    }
}
