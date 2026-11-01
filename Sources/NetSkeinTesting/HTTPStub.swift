import AsyncHTTPClient
import NIOCore
import NIOHTTP1

/// A canned answer for requests with a given method and URL.
///
/// ```swift
/// let stub = HTTPStub(
///     method: .GET,
///     url: "https://api.example.com/me",
///     outcome: .response(status: .ok, headers: ["Content-Type": "application/json"], body: ByteBuffer(string: "{}"))
/// )
/// ```
///
/// Several stubs for the same route answer successive calls in order; see ``MockHTTPClient``.
public struct HTTPStub: Sendable {
    /// What a matching request gets back.
    public enum Outcome: Sendable {
        /// A response with this status, headers and body.
        case response(status: HTTPResponseStatus, headers: HTTPHeaders, body: ByteBuffer? = nil)
        /// The request fails with this error, as if the connection had failed.
        case error(any Error & Sendable)
    }

    public typealias Validator = @Sendable (HTTPClientRequest) throws -> Void

    public let method: HTTPMethod
    public let urlMatcher: @Sendable (String) -> Bool
    /// How long to wait before answering, to simulate a slow server.
    public let delay: TimeAmount?
    /// Runs for every matching request before it is answered; throw from it to fail the request,
    /// or use test expectations inside it to check what was sent.
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
