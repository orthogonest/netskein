import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

/// A response whose body is read piece by piece, as it arrives from the server.
///
/// Returned by ``NetSkeinRequest/stream()`` once the response headers have arrived. The body
/// is still on its way. Iterate it to receive each piece of the body as the server sends it:
///
/// ```swift
/// let response = try await client.get(url).stream()
/// for try await chunk in response {
///     // handle each ByteBuffer as it arrives
/// }
/// ```
///
/// Reading is pulled by the loop: while the loop is busy with one piece, no more of the body is
/// read from the network, so a slow consumer slows the download instead of filling memory.
/// Leaving the loop early, with `break` or by throwing, stops reading and closes the
/// connection.
///
/// The body can be iterated once. Errors thrown while iterating are always ``NetSkeinError``:
/// `networkFailure` when the connection drops or the task is cancelled. A failure while
/// iterating is never retried, since the earlier pieces have already reached the caller.
///
/// ## Topics
///
/// ### Reading the Head
///
/// - ``status``
/// - ``headers``
/// - ``expectedContentLength``
///
/// ### Reading the Body
///
/// - ``makeAsyncIterator()``
/// - ``AsyncIterator``
/// - ``lines(maxLineLength:)``
public struct NetSkeinStream: Sendable {
    /// The response status, always in `200..<300`.
    public let status: HTTPResponseStatus
    /// The response headers.
    public let headers: HTTPHeaders
    private let body: HTTPClientResponse.Body

    init(_ response: HTTPClientResponse) {
        status = response.status
        headers = response.headers
        body = response.body
    }
}

extension NetSkeinStream {
    /// The body size from `Content-Length`, when the server sent one.
    public var expectedContentLength: Int? {
        headers.first(name: "Content-Length").flatMap(Int.init)
    }

    /// The body as lines, each delivered as soon as its line ending arrives.
    ///
    /// Use it to check ``status`` or ``headers`` before reading lines. See ``NetSkeinLines`` for
    /// how lines are split.
    ///
    /// - Parameter maxLineLength: The longest line accepted, in bytes (default: 1 MiB). A longer
    ///   one makes the loop throw ``NetSkeinError/Kind/invalidPayload``. `nil` removes the
    ///   limit.
    /// - Returns: The body as lines. Iterate either the stream or its lines, not both.
    public func lines(maxLineLength: Int? = 1024 * 1024) -> NetSkeinLines {
        NetSkeinLines(self, maxLineLength: maxLineLength)
    }
}

extension NetSkeinStream: AsyncSequence {
    /// A piece of the body.
    public typealias Element = ByteBuffer

    /// Returns an iterator over the body's pieces. Call it once.
    ///
    /// - Returns: The iterator.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: body.makeAsyncIterator())
    }

    /// Reads the body's pieces as they arrive.
    public struct AsyncIterator: AsyncIteratorProtocol {
        /// The error thrown while reading.
        public typealias Failure = NetSkeinError

        private var base: HTTPClientResponse.Body.AsyncIterator

        fileprivate init(base: HTTPClientResponse.Body.AsyncIterator) {
            self.base = base
        }

        /// The next piece of the body, or `nil` once it has fully arrived.
        ///
        /// - Returns: The next piece, or `nil` at the end of the body.
        /// - Throws: A ``NetSkeinError`` of kind ``NetSkeinError/Kind/networkFailure`` when the
        ///   connection drops or the task is cancelled.
        public mutating func next() async throws(Failure) -> ByteBuffer? {
            try checkCancellation()

            let chunk: ByteBuffer?
            do {
                chunk = try await base.next()
            } catch {
                throw NetSkeinError.custom(
                    kind: .networkFailure,
                    message:
                        "Network connection dropped while streaming the response body: \(error.localizedDescription)",
                    underlyingError: error
                )
            }

            // A cancelled body can end early. Report the cancellation instead of looking complete
            if chunk == nil { try checkCancellation() }
            return chunk
        }
    }
}
