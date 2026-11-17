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
/// try HTTPStub.get("https://api.example.com/me")
///     .json(Profile(name: "Ada"))
///     .header("Cache-Control", "max-age=60")
///
/// HTTPStub.post("https://api.example.com/items").status(.created).text("saved")
/// HTTPStub.get("https://api.example.com/feed").fail(with: OfflineError())
/// ```
///
/// A stub answers `200 OK` with no body until told otherwise. Several stubs for the same route
/// answer successive calls in order. See ``MockHTTPClient``.
///
/// ## Topics
///
/// ### Starting a Stub
///
/// - ``get(_:)``
/// - ``post(_:)``
/// - ``put(_:)``
/// - ``patch(_:)``
/// - ``delete(_:)``
/// - ``request(_:url:)``
/// - ``request(_:matching:)``
///
/// ### Describing the Response
///
/// - ``status(_:)``
/// - ``header(_:_:)``
/// - ``headers(_:)``
/// - ``body(_:)``
/// - ``text(_:)``
/// - ``json(_:encoder:)``
/// - ``fail(with:)``
///
/// ### Timing and Checks
///
/// - ``delay(_:)``
/// - ``validate(_:)``
/// - ``Validator``
///
/// ### Creating a Stub Directly
///
/// - ``init(method:url:delay:requestValidator:outcome:)``
/// - ``init(method:urlMatcher:delay:requestValidator:outcome:)``
/// - ``Outcome``
///
/// ### Reading a Stub
///
/// - ``method``
/// - ``urlMatcher``
/// - ``delay``
/// - ``requestValidator``
/// - ``outcome``
public struct HTTPStub: Sendable {
    /// What a matching request gets back.
    public enum Outcome: Sendable {
        /// A response with this status, headers and body.
        case response(status: HTTPResponseStatus, headers: HTTPHeaders, body: ByteBuffer? = nil)
        /// The request fails with this error, as if the connection had failed.
        ///
        /// A `NetSkeinError` reaches the caller unchanged. Any other error is reported as
        /// `NetSkeinError.Kind.networkFailure`, which `RetryPolicy.standard` retries.
        case error(any Error & Sendable)
    }

    /// Checks a request before it is answered. Throw to fail the request.
    public typealias Validator = @Sendable (HTTPClientRequest) throws -> Void

    /// The method this stub answers.
    public let method: HTTPMethod
    /// Returns whether this stub answers a request to the given URL.
    public let urlMatcher: @Sendable (String) -> Bool
    /// How long to wait before answering, to simulate a slow server.
    public private(set) var delay: TimeAmount?
    /// Runs for every matching request before it is answered. Throw from it to fail the request,
    /// or use test expectations inside it to check what was sent.
    public private(set) var requestValidator: Validator?
    /// What a matching request gets back.
    public private(set) var outcome: Outcome

    /// Creates a stub for requests to exactly `url`.
    ///
    /// ``get(_:)`` and the other starting methods read better in most tests.
    ///
    /// - Parameters:
    ///   - method: The method this stub answers.
    ///   - url: The URL this stub answers, compared as written, query included.
    ///   - delay: How long to wait before answering (default: `nil`, no wait).
    ///   - requestValidator: Checks each matching request before it is answered
    ///     (default: `nil`).
    ///   - outcome: What a matching request gets back.
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

    /// Creates a stub for requests whose URL `urlMatcher` accepts.
    ///
    /// ``request(_:matching:)`` reads better in most tests.
    ///
    /// - Parameters:
    ///   - method: The method this stub answers.
    ///   - urlMatcher: Returns whether this stub answers a request to the given URL.
    ///   - delay: How long to wait before answering (default: `nil`, no wait).
    ///   - requestValidator: Checks each matching request before it is answered
    ///     (default: `nil`).
    ///   - outcome: What a matching request gets back.
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
    ///
    /// - Parameter url: The URL this stub answers, compared as written, query included.
    /// - Returns: The stub.
    public static func get(_ url: String) -> Self {
        request(.GET, url: url)
    }

    /// A stub for `POST` requests to `url`, answering `200 OK` with no body.
    ///
    /// - Parameter url: The URL this stub answers, compared as written, query included.
    /// - Returns: The stub.
    public static func post(_ url: String) -> Self {
        request(.POST, url: url)
    }

    /// A stub for `PUT` requests to `url`, answering `200 OK` with no body.
    ///
    /// - Parameter url: The URL this stub answers, compared as written, query included.
    /// - Returns: The stub.
    public static func put(_ url: String) -> Self {
        request(.PUT, url: url)
    }

    /// A stub for `PATCH` requests to `url`, answering `200 OK` with no body.
    ///
    /// - Parameter url: The URL this stub answers, compared as written, query included.
    /// - Returns: The stub.
    public static func patch(_ url: String) -> Self {
        request(.PATCH, url: url)
    }

    /// A stub for `DELETE` requests to `url`, answering `200 OK` with no body.
    ///
    /// - Parameter url: The URL this stub answers, compared as written, query included.
    /// - Returns: The stub.
    public static func delete(_ url: String) -> Self {
        request(.DELETE, url: url)
    }

    /// A stub for `method` requests to `url`, answering `200 OK` with no body.
    ///
    /// - Parameters:
    ///   - method: The method this stub answers, such as `.HEAD` or `.OPTIONS`.
    ///   - url: The URL this stub answers, compared as written, query included.
    /// - Returns: The stub.
    public static func request(_ method: HTTPMethod, url: String) -> Self {
        HTTPStub(method: method, url: url, outcome: .response(status: .ok, headers: [:]))
    }

    /// A stub for `method` requests whose URL `matches` accepts, answering `200 OK` with no body.
    ///
    /// Use it for URLs that change between runs, such as ones with a timestamp in the query:
    ///
    /// ```swift
    /// HTTPStub.request(.GET) { $0.hasPrefix("https://api.example.com/feed?") }
    /// ```
    ///
    /// - Parameters:
    ///   - method: The method this stub answers.
    ///   - matches: Returns whether this stub answers a request to the given URL.
    /// - Returns: The stub.
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
    ///
    /// - Parameter status: The response status, such as `.created` or `.serviceUnavailable`.
    /// - Returns: A copy of the stub with this status.
    public func status(_ status: HTTPResponseStatus) -> Self {
        updatingResponse { $0.status = status }
    }

    /// Sets the response header `name` to `value`, replacing any value it had.
    ///
    /// - Parameters:
    ///   - name: The header name, such as `Cache-Control`.
    ///   - value: The header value.
    /// - Returns: A copy of the stub with this header.
    public func header(_ name: String, _ value: String) -> Self {
        updatingResponse { $0.headers.replaceOrAdd(name: name, value: value) }
    }

    /// Replaces all response headers with `headers`.
    ///
    /// - Parameter headers: The response headers.
    /// - Returns: A copy of the stub with only these headers.
    public func headers(_ headers: HTTPHeaders) -> Self {
        updatingResponse { $0.headers = headers }
    }

    /// Answers with `bytes` as the body.
    ///
    /// - Parameter bytes: The response body.
    /// - Returns: A copy of the stub with this body.
    public func body(_ bytes: ByteBuffer) -> Self {
        updatingResponse { $0.body = bytes }
    }

    /// Answers with `text` as the body, with `Content-Type: text/plain; charset=utf-8`.
    ///
    /// - Parameter text: The response body, encoded as UTF-8.
    /// - Returns: A copy of the stub with this body and content type.
    public func text(_ text: String) -> Self {
        header("Content-Type", "text/plain; charset=utf-8").body(ByteBuffer(string: text))
    }

    /// Answers with `value` encoded as JSON, with `Content-Type: application/json`.
    ///
    /// - Parameters:
    ///   - value: The value to encode as the response body.
    ///   - encoder: The encoder to use (default: a `JSONEncoder` with its default settings).
    /// - Returns: A copy of the stub with this body and content type.
    /// - Throws: The encoder's error when `value` cannot be encoded.
    public func json(_ value: some Encodable, encoder: JSONEncoder = JSONEncoder()) throws -> Self {
        let data = try encoder.encode(value)
        return header("Content-Type", "application/json").body(ByteBuffer(bytes: data))
    }

    /// Fails matching requests with `error`, as if the connection had failed. Response settings
    /// made before or after are ignored.
    ///
    /// Pass a `NetSkeinError` to fail with a specific kind, such as `timedOut`. Any other error
    /// is reported as `NetSkeinError.Kind.networkFailure`, which `RetryPolicy.standard` retries.
    ///
    /// - Parameter error: The error the request fails with.
    /// - Returns: A copy of the stub that fails.
    public func fail(with error: any Error & Sendable) -> Self {
        var copy = self
        copy.outcome = .error(error)
        return copy
    }
}

// MARK: - Timing and Checks

extension HTTPStub {
    /// Waits `delay` before answering, to simulate a slow server.
    ///
    /// The wait is real time, and ends early when the task is cancelled. It counts towards a
    /// call timeout, so a test can make a call time out. An attempt timeout does not apply,
    /// since ``MockHTTPClient`` ignores it.
    ///
    /// - Parameter delay: How long to wait.
    /// - Returns: A copy of the stub that waits.
    public func delay(_ delay: TimeAmount) -> Self {
        var copy = self
        copy.delay = delay
        return copy
    }

    /// Runs `validator` for every matching request before it is answered. Throw from it to fail
    /// the request, or use test expectations inside it to check what was sent.
    ///
    /// ```swift
    /// HTTPStub.post("https://api.example.com/items").validate { request in
    ///     #expect(request.headers.first(name: "Authorization") == "Bearer token")
    /// }
    /// ```
    ///
    /// An error it throws fails the request like ``fail(with:)`` does.
    ///
    /// - Parameter validator: Checks each matching request.
    /// - Returns: A copy of the stub with this validator, replacing any set before.
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

    /// A copy with the response changed by `change`. A failing stub keeps failing.
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
