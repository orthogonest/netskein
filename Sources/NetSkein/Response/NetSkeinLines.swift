import NIOCore
import NIOHTTP1

/// A response whose body is read line by line, each line delivered as soon as it is complete.
///
/// Returned by ``NetSkeinRequest/lines(maxLineLength:)``, or by ``NetSkeinStream/lines(maxLineLength:)``
/// when the headers should be checked first. Suited to line-based formats such as server-sent
/// events, JSON Lines and log streams:
///
/// ```swift
/// for try await line in try await client.get(url).lines() {
///     print(line)
/// }
/// ```
///
/// Lines end at `\n`, `\r\n` or a lone `\r`, and are delivered without their line ending.
/// Empty lines are delivered too, as `""`, since formats like server-sent events use them to
/// separate entries. A last line without a line ending is delivered once the body ends; a
/// body ending with a line ending does not produce an extra empty line. Each line is decoded
/// as UTF-8 once complete, so a character split across network packets stays intact, and
/// invalid bytes become `U+FFFD`.
///
/// Like ``NetSkeinStream``, the body can be iterated once, and errors thrown while iterating
/// are always ``NetSkeinError``.
public struct NetSkeinLines: Sendable {
    private let stream: NetSkeinStream
    /// `nil` means no limit.
    private let maxLineLength: Int?

    init(_ stream: NetSkeinStream, maxLineLength: Int?) {
        self.stream = stream
        self.maxLineLength = maxLineLength.map { Swift.max(0, $0) }
    }
}

extension NetSkeinLines {
    public var status: HTTPResponseStatus { stream.status }
    public var headers: HTTPHeaders { stream.headers }
}

extension NetSkeinLines: AsyncSequence {
    public typealias Element = String

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(chunks: stream.makeAsyncIterator(), maxLineLength: maxLineLength)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        public typealias Failure = NetSkeinError

        private static let lineFeed = UInt8(ascii: "\n")
        private static let carriageReturn = UInt8(ascii: "\r")

        private var chunks: NetSkeinStream.AsyncIterator

        private let maxLineLength: Int?

        /// The part of the latest chunk not yet split into lines.
        private var pending: ByteBuffer

        /// The bytes of the line being collected.
        private var line: [UInt8]

        /// Set after a `\r`, so a `\n` right after it, even in the next chunk, ends no new line.
        private var skipsLineFeed: Bool

        private var isFinished: Bool

        fileprivate init(chunks: NetSkeinStream.AsyncIterator, maxLineLength: Int?) {
            self.chunks = chunks
            self.maxLineLength = maxLineLength
            self.pending = ByteBuffer()
            self.line = []
            self.skipsLineFeed = false
            self.isFinished = false
        }

        /// The next line, or `nil` once the body has ended.
        ///
        /// - Throws: ``NetSkeinError`` of kind `invalidPayload` when a line is longer than
        ///   `maxLineLength` bytes, or of kind `networkFailure` when the connection drops or the
        ///   task is cancelled.
        public mutating func next() async throws(Failure) -> String? {
            while !isFinished {
                if let line = try lineFromPending() { return line }

                guard let chunk = try await chunks.next() else {
                    isFinished = true
                    return line.isEmpty ? nil : takeLine()
                }
                pending = chunk
            }
            return nil
        }

        /// The next complete line in the bytes received so far, or `nil` when they end mid-line;
        /// the incomplete rest is kept for when more of the body arrives.
        private mutating func lineFromPending() throws(NetSkeinError) -> String? {
            if skipsLineFeed, let first = pending.readableBytesView.first {
                skipsLineFeed = false
                if first == Self.lineFeed { pending.moveReaderIndex(forwardBy: 1) }
            }

            let bytes = pending.readableBytesView
            guard
                let end = bytes.firstIndex(where: {
                    $0 == Self.lineFeed || $0 == Self.carriageReturn
                })
            else {
                try append(bytes)
                pending.moveReaderIndex(forwardBy: bytes.count)
                return nil
            }

            try append(bytes[bytes.startIndex..<end])
            skipsLineFeed = bytes[end] == Self.carriageReturn
            pending.moveReaderIndex(forwardBy: end - bytes.startIndex + 1)
            return takeLine()
        }

        private mutating func append(_ bytes: ByteBufferView.SubSequence) throws(NetSkeinError) {
            line.append(contentsOf: bytes)
            if let maxLineLength, line.count > maxLineLength {
                throw NetSkeinError.custom(
                    kind: .invalidPayload,
                    message: "A line in the response body is longer than \(maxLineLength) bytes."
                )
            }
        }

        private mutating func takeLine() -> String {
            let text = String(decoding: line, as: UTF8.self)
            line.removeAll(keepingCapacity: true)
            return text
        }
    }
}
