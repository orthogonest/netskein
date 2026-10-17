import NIOHTTP1

public final class NetSkeinCookieJar: @unchecked Sendable {
    private var cookies: [String: [String: String]]
    private let mutex: Mutex

    public init() {
        cookies = [:]
        mutex = Mutex()
    }

    public func setCookie(host: String, name: String, value: String) {
        mutex.withLock {
            if cookies[host] == nil { cookies[host] = [:] }
            cookies[host]?[name] = value
        }
    }

    public func cookieHeader(for host: String) -> String? {
        mutex.withLock {
            guard let hostCookies = cookies[host], !hostCookies.isEmpty else { return nil }
            return hostCookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        }
    }

    public func clear() {
        mutex.withLock {
            cookies.removeAll()
        }
    }
}
