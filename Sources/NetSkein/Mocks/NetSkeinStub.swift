import AsyncHTTPClient
import NIOCore
import NIOHTTP1

public struct NetSkeinStub: Sendable {
    public enum Outcome: Sendable {
        case success(status: HTTPResponseStatus, headers: HTTPHeaders, body: ByteBuffer?)
        case failure(any Error & Sendable)
    }

    public let method: HTTPMethod
    public let urlMatcher: @Sendable (String) -> Bool
    public let delay: TimeAmount?
    public let requestValidator: (@Sendable (HTTPClientRequest) throws -> Void)?
    public let outcome: Outcome

    public init(
        method: HTTPMethod,
        url: String,
        delay: TimeAmount? = nil,
        requestValidator: (@Sendable (HTTPClientRequest) throws -> Void)? = nil,
        outcome: Outcome
    ) {
        self.method = method
        self.urlMatcher = { $0 == url }
        self.delay = delay
        self.requestValidator = requestValidator
        self.outcome = outcome
    }

    public init(
        method: HTTPMethod,
        urlMatcher: @escaping @Sendable (String) -> Bool,
        delay: TimeAmount? = nil,
        requestValidator: (@Sendable (HTTPClientRequest) throws -> Void)? = nil,
        outcome: Outcome
    ) {
        self.method = method
        self.urlMatcher = urlMatcher
        self.delay = delay
        self.requestValidator = requestValidator
        self.outcome = outcome
    }
}

extension NetSkeinStub: Equatable {
    public static func == (lhs: NetSkeinStub, rhs: NetSkeinStub) -> Bool {
        lhs.method == rhs.method
            && lhs.delay == rhs.delay
            && String(describing: lhs.outcome) == String(describing: rhs.outcome)
    }
}

extension NetSkeinStub: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(method.rawValue)
        hasher.combine(delay)
        hasher.combine(String(describing: outcome))
    }
}
