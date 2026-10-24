import NIOConcurrencyHelpers
import NIOHTTP1

public final class CookieJar: Sendable {
    private let storage: NIOLockedValueBox<[String: [String: String]]>

    public init() {
        storage = NIOLockedValueBox([:])
    }
}

extension CookieJar {
    public func setCookie(host: String, name: String, value: String) {
        storage.withLockedValue { cookies in
            if cookies[host] == nil { cookies[host] = [:] }
            cookies[host]?[name] = value
        }
    }

    public func cookieHeader(for host: String) -> String? {
        storage.withLockedValue { cookies in
            guard let hostCookies = cookies[host], !hostCookies.isEmpty else { return nil }
            return hostCookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        }
    }

    public func clear() {
        storage.withLockedValue { cookies in cookies.removeAll() }
    }
}
