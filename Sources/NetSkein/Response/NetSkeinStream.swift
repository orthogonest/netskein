import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

/// A response whose body is read piece by piece, as it arrives from the server.
///
/// Returned by ``NetSkeinRequest/stream()`` once the response headers have arrived; the body
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
public struct NetSkeinStream: Sendable {
    public let status: HTTPResponseStatus
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
    /// See ``NetSkeinRequest/lines(maxLineLength:)`` for how lines are split.
    public func lines(maxLineLength: Int? = 1024 * 1024) -> NetSkeinLines {
        NetSkeinLines(self, maxLineLength: maxLineLength)
    }
}

extension NetSkeinStream: AsyncSequence {
    public typealias Element = ByteBuffer

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: body.makeAsyncIterator())
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        public typealias Failure = NetSkeinError

        private var base: HTTPClientResponse.Body.AsyncIterator

        fileprivate init(base: HTTPClientResponse.Body.AsyncIterator) {
            self.base = base
        }

        /// The next piece of the body, or `nil` once it has fully arrived.
        ///
        /// - Throws: ``NetSkeinError`` of kind `networkFailure` when the connection drops or
        ///   the task is cancelled.
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

            // A cancelled body can end early; report the cancellation instead of looking complete
            if chunk == nil { try checkCancellation() }
            return chunk
        }
    }
}
