import NIOConcurrencyHelpers
import NIOHTTP1

public final class NetSkeinCookieJar: @unchecked Sendable {
    private var cookies: [String: [String: String]]
    private let lock: NIOLock

    public init() {
        cookies = [:]
        lock = NIOLock()
    }
}

public extension NetSkeinCookieJar {
    func setCookie(host: String, name: String, value: String) {
        lock.withLock {
            if cookies[host] == nil { cookies[host] = [:] }
            cookies[host]?[name] = value
        }
    }

    func cookieHeader(for host: String) -> String? {
        lock.withLock {
            guard let hostCookies = cookies[host], !hostCookies.isEmpty else { return nil }
            return hostCookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        }
    }

    func clear() {
        lock.withLock {
            cookies.removeAll()
        }
    }
}
