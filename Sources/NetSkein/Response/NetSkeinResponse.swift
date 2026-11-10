import AsyncHTTPClient
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1

/// A response whose body has been collected in memory, returned by ``NetSkeinRequest/send()``.
///
/// Read the body as the type you expect:
///
/// ```swift
/// let response = try await client.get(url).send()
///
/// let user = try response.validate().json(User.self)
/// let html = response.text()
/// let raw = response.bytes()
/// ```
///
/// A response is returned for any status, so check it with ``validate()`` or ``status``.
///
/// ## Topics
///
/// ### Checking the Status
///
/// - ``status``
/// - ``validate()``
/// - ``validate(decoding:decoder:)``
///
/// ### Reading the Body
///
/// - ``json(_:decoder:)``
/// - ``text(upTo:)``
/// - ``bytes()``
///
/// ### Reading Headers
///
/// - ``headers``
///
/// ### Creating a Response
///
/// - ``init(underlyingResponse:maxBytes:)``
public struct NetSkeinResponse: Sendable {
    /// The status the server returned, such as `.ok` or `.notFound`.
    public let status: HTTPResponseStatus
    /// The response headers. Header names are matched case-insensitively:
    /// `headers["content-type"]` finds `Content-Type`.
    public let headers: HTTPHeaders
    /// `nil` when the body is empty, never an empty buffer.
    private let body: ByteBuffer?

    /// Creates a response by collecting the body of an AsyncHTTPClient response.
    ///
    /// You rarely need this: ``NetSkeinRequest/send()`` creates responses for you. It's useful in a
    /// custom transport or a test.
    ///
    /// - Parameters:
    ///   - underlyingResponse: The response to collect.
    ///   - maxBytes: The largest body accepted.
    /// - Throws: ``NetSkeinError/Kind/networkFailure`` when the body is larger than `maxBytes` or
    ///   fails while arriving.
    public init(underlyingResponse: HTTPClientResponse, maxBytes: Int) async throws {
        self.status = underlyingResponse.status
        self.headers = underlyingResponse.headers

        do {
            let collectedBytes = try await underlyingResponse.body.collect(upTo: maxBytes)
            self.body = collectedBytes.readableBytes > 0 ? collectedBytes : nil
        } catch {
            throw NetSkeinError.custom(
                kind: .networkFailure,
                message: "Failed to collect response body sequence: \(error.localizedDescription)",
                underlyingError: error
            )
        }
    }
}

extension NetSkeinResponse {
    /// Returns the response unchanged when its status is in `200..<300`, and throws otherwise.
    ///
    /// Chain it between ``NetSkeinRequest/send()`` and reading the body.
    ///
    /// - Throws: ``NetSkeinError/badStatus(_:)``, of kind ``NetSkeinError/Kind/clientError`` for
    ///   `4xx` and other statuses below `500`, or ``NetSkeinError/Kind/serverError`` for `5xx`.
    @discardableResult
    public func validate() throws(NetSkeinError) -> Self {
        guard status.code >= 200 && status.code < 300 else { throw .badStatus(status) }
        return self
    }

    /// Returns the response unchanged when its status is in `200..<300`, and otherwise throws the
    /// error the server described in the body.
    ///
    /// Use it for APIs that send a JSON error body:
    ///
    /// ```swift
    /// struct APIError: Error, Decodable {
    ///     let code: String
    ///     let message: String
    /// }
    ///
    /// do {
    ///     let user = try await client.get(url)
    ///         .send()
    ///         .validate(decoding: APIError.self)
    ///         .json(User.self)
    /// } catch let error as APIError {
    ///     // The server's own error.
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - errorType: The error type to decode from the body.
    ///   - decoder: The decoder to use (default: a new `JSONDecoder`).
    /// - Returns: The response, unchanged.
    /// - Throws: The decoded error when the status is outside `200..<300` and the body decodes as
    ///   `E`. When it doesn't, ``NetSkeinError/badStatus(_:)``, as ``validate()`` throws.
    @discardableResult
    public func validate<E: Error & Decodable>(
        decoding errorType: E.Type,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> Self {
        guard status.code >= 200 && status.code < 300 else {
            if let body, let decodedError = try? decoder.decode(E.self, from: body) {
                throw decodedError
            }
            throw NetSkeinError.badStatus(status)
        }
        return self
    }

    /// Returns the body as raw bytes, or `nil` when the body is empty.
    public func bytes() -> ByteBuffer? {
        body
    }

    /// Returns the body decoded as UTF-8 text, or `nil` when the body is empty.
    ///
    /// Bytes that aren't valid UTF-8 become the replacement character `�`.
    ///
    /// - Parameter maxLength: Not used yet: the whole body is always decoded.
    /// - Returns: The body as text, or `nil` when it's empty.
    public func text(upTo maxLength: Int? = nil) -> String? {
        guard let body else { return nil }
        return body.getString(at: body.readerIndex, length: body.readableBytes)
    }

    /// Decodes the body as JSON into `T`.
    ///
    /// - Parameters:
    ///   - type: The type to decode, such as `User.self`.
    ///   - decoder: The decoder to use (default: a new `JSONDecoder`). Pass your own to change
    ///     its date or key strategies.
    /// - Throws: ``NetSkeinError/Kind/emptyResponseBody`` when the body is empty, or
    ///   ``NetSkeinError/Kind/invalidPayload`` when it doesn't decode as `T`. The decoding error is
    ///   kept as the underlying error.
    /// - Returns: The decoded value.
    public func json<T: Decodable>(
        _ type: T.Type,
        decoder: JSONDecoder = JSONDecoder()
    ) throws(NetSkeinError) -> T {
        guard let body else { throw .simple(.emptyResponseBody) }
        do {
            return try decoder.decode(T.self, from: body)
        } catch {
            throw .custom(
                kind: .invalidPayload,
                message: "Failed to decode JSON payload: \(error.localizedDescription)",
                underlyingError: error
            )
        }
    }
}
