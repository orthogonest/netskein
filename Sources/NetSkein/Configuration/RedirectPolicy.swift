import AsyncHTTPClient
import NIOCore
import NIOHTTP1

public enum RedirectPolicy: Sendable {
    case `default`
    case disabled
    case limited(maxRedirects: Int)
}

extension RedirectPolicy {
    var underlyingConfiguration: HTTPClient.Configuration.RedirectConfiguration {
        switch self {
        case .default: return .follow(max: 5, allowCycles: false)
        case .disabled: return .disallow
        case let .limited(maxRedirects):
            return maxRedirects > 0 ? .follow(max: maxRedirects, allowCycles: false) : .disallow
        }
    }
}
