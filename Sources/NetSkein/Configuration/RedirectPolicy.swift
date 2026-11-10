import AsyncHTTPClient
import NIOCore
import NIOHTTP1

/// Whether a client follows redirects, and how many in a row.
///
/// Set with ``NetSkeinClientBuilder/redirectPolicy(_:)``. A request fails with
/// ``NetSkeinError/Kind/networkFailure`` when it gets more redirects than the policy allows, or
/// one that leads back to a URL it already visited.
public enum RedirectPolicy: Sendable {
    /// Follows up to 5 redirects in a row. The default.
    case `default`
    /// Follows no redirects: a `3xx` response is returned as it is.
    case disabled
    /// Follows up to `maxRedirects` redirects in a row; 0 or less acts like ``disabled``.
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
