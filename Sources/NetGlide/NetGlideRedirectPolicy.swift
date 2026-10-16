import AsyncHTTPClient
import NIOCore
import NIOHTTP1

public enum NetGlideRedirectPolicy: Sendable {
    case `default`
    case none
    case limited(Int)
}

extension NetGlideRedirectPolicy {
    var underlyingConfiguration: HTTPClient.Configuration.RedirectConfiguration {
        switch self {
        case .default:
            return .follow(max: 5, allowCycles: false)
        case .none:
            return .disallow
        case let .limited(limit):
            return limit > 0 ? .follow(max: limit, allowCycles: false) : .disallow
        }
    }
}
