import AsyncHTTPClient
import NIOCore
import NIOHTTP1

public struct HTTPStub: Sendable {
    public enum Outcome: Sendable {
        case response(status: HTTPResponseStatus, headers: HTTPHeaders, body: ByteBuffer? = nil)
        case error(any Error & Sendable)
    }

    public typealias Validator = @Sendable (HTTPClientRequest) throws -> Void

    public let method: HTTPMethod
    public let urlMatcher: @Sendable (String) -> Bool
    public let delay: TimeAmount?
    public let requestValidator: Validator?
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

extension HTTPStub: Equatable {
    public static func == (lhs: HTTPStub, rhs: HTTPStub) -> Bool {
        lhs.method == rhs.method
            && lhs.delay == rhs.delay
            && String(describing: lhs.outcome) == String(describing: rhs.outcome)
    }
}

extension HTTPStub: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(method.rawValue)
        hasher.combine(delay)
        hasher.combine(String(describing: outcome))
    }
}
