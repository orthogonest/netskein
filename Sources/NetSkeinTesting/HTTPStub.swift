import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

/// A canned answer for requests with a given method and URL.
///
/// Start a stub with the method it answers, then describe the response, the same way a request
/// is described with `NetSkeinRequest`:
///
/// ```swift
/// HTTPStub.get("https://api.example.com/me")
///     .json(Profile(name: "Ada"))
///     .header("Cache-Control", "max-age=60")
///
/// HTTPStub.post("https://api.example.com/items").status(.created).text("saved")
/// HTTPStub.get("https://api.example.com/feed").fail(with: OfflineError())
/// ```
///
/// A stub answers `200 OK` with no body until told otherwise. Several stubs for the same route
/// answer successive calls in order; see ``MockHTTPClient``.
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
    public private(set) var delay: TimeAmount?
    /// Runs for every matching request before it is answered; throw from it to fail the request,
    /// or use test expectations inside it to check what was sent.
    public private(set) var requestValidator: Validator?
    public private(set) var outcome: Outcome

    public init(
        method: HTTPMethod,
        url: String,
        delay: TimeAmount? = nil,
        requestValidator: (@Sendable (HTTPClientRequest) throws -> Void)? = nil,
        outcome: Outcome
    ) {
        self.init(
            method: method,
            urlMatcher: { $0 == url },
            delay: delay,
            requestValidator: requestValidator,
            outcome: outcome
        )
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

// MARK: - Starting a Stub

extension HTTPStub {
    /// A stub for `GET` requests to `url`, answering `200 OK` with no body.
    public static func get(_ url: String) -> Self {
        request(.GET, url: url)
    }

    /// A stub for `POST` requests to `url`, answering `200 OK` with no body.
    public static func post(_ url: String) -> Self {
        request(.POST, url: url)
    }

    /// A stub for `PUT` requests to `url`, answering `200 OK` with no body.
    public static func put(_ url: String) -> Self {
        request(.PUT, url: url)
    }

    /// A stub for `PATCH` requests to `url`, answering `200 OK` with no body.
    public static func patch(_ url: String) -> Self {
        request(.PATCH, url: url)
    }

    /// A stub for `DELETE` requests to `url`, answering `200 OK` with no body.
    public static func delete(_ url: String) -> Self {
        request(.DELETE, url: url)
    }

    /// A stub for `method` requests to `url`, answering `200 OK` with no body.
    public static func request(_ method: HTTPMethod, url: String) -> Self {
        HTTPStub(method: method, url: url, outcome: .response(status: .ok, headers: [:]))
    }

    /// A stub for `method` requests whose URL `matches` accepts, answering `200 OK` with no body.
    public static func request(
        _ method: HTTPMethod,
        matching matches: @escaping @Sendable (String) -> Bool
    ) -> Self {
        HTTPStub(method: method, urlMatcher: matches, outcome: .response(status: .ok, headers: [:]))
    }
}

// MARK: - Describing the Response

extension HTTPStub {
    /// Answers with `status`.
    public func status(_ status: HTTPResponseStatus) -> Self {
        updatingResponse { $0.status = status }
    }

    /// Sets the response header `name` to `value`, replacing any value it had.
    public func header(_ name: String, _ value: String) -> Self {
        updatingResponse { $0.headers.replaceOrAdd(name: name, value: value) }
    }

    /// Replaces all response headers with `headers`.
    public func headers(_ headers: HTTPHeaders) -> Self {
        updatingResponse { $0.headers = headers }
    }

    /// Answers with `bytes` as the body.
    public func body(_ bytes: ByteBuffer) -> Self {
        updatingResponse { $0.body = bytes }
    }

    /// Answers with `text` as the body, with `Content-Type: text/plain; charset=utf-8`.
    public func text(_ text: String) -> Self {
        header("Content-Type", "text/plain; charset=utf-8").body(ByteBuffer(string: text))
    }

    /// Answers with `value` encoded as JSON, with `Content-Type: application/json`.
    ///
    /// - Throws: The encoder's error when `value` cannot be encoded.
    public func json(_ value: some Encodable, encoder: JSONEncoder = JSONEncoder()) throws -> Self {
        let data = try encoder.encode(value)
        return header("Content-Type", "application/json").body(ByteBuffer(bytes: data))
    }

    /// Fails matching requests with `error`, as if the connection had failed. Response settings
    /// made before or after are ignored.
    public func fail(with error: any Error & Sendable) -> Self {
        var copy = self
        copy.outcome = .error(error)
        return copy
    }
}

// MARK: - Timing and Checks

extension HTTPStub {
    /// Waits `delay` before answering, to simulate a slow server.
    public func delay(_ delay: TimeAmount) -> Self {
        var copy = self
        copy.delay = delay
        return copy
    }

    /// Runs `validator` for every matching request before it is answered; throw from it to fail
    /// the request, or use test expectations inside it to check what was sent.
    public func validate(_ validator: @escaping Validator) -> Self {
        var copy = self
        copy.requestValidator = validator
        return copy
    }
}

extension HTTPStub {
    private struct Response {
        var status: HTTPResponseStatus
        var headers: HTTPHeaders
        var body: ByteBuffer?
    }

    /// A copy with the response changed by `change`; a failing stub keeps failing.
    private func updatingResponse(_ change: (inout Response) -> Void) -> Self {
        guard case let .response(status, headers, body) = outcome else { return self }
        var response = Response(status: status, headers: headers, body: body)
        change(&response)

        var copy = self
        copy.outcome = .response(
            status: response.status,
            headers: response.headers,
            body: response.body
        )
        return copy
    }
}
