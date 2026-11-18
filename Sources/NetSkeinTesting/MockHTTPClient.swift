import AsyncHTTPClient
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NetSkein

/// A transport that answers requests from ``HTTPStub``s instead of the network.
///
/// Each request is answered by the stubs matching its method and URL, in order: the first call
/// to a route gets the first matching stub, the second call the second, and calls beyond the
/// last stub keep getting the last one. A route is a method and an exact URL, so a stub made
/// with ``HTTPStub/request(_:matching:)`` counts calls separately for each URL it matches.
///
/// A request without a matching stub fails with an `invalidRequest` naming the request, so a
/// missing stub is reported once, never retried as a network failure.
///
/// ``NetSkein/NetSkeinClient/testing()`` creates one for you. Reach it through
/// ``NetSkein/NetSkeinClient/mock`` to check what was sent.
public final class MockHTTPClient: Sendable {
    let stubsBox: NIOLockedValueBox<[HTTPStub]>
    /// How many requests each route received, keyed by method and URL.
    let callCounts: NIOLockedValueBox<[String: Int]>
    let onShutdown: NIOLockedValueBox<(@Sendable () async throws -> Void)?>
    private let received: NIOLockedValueBox<[HTTPClientRequest]>

    /// Creates a transport that answers from `stubs`.
    ///
    /// - Parameters:
    ///   - stubs: The stubs that answer requests, in the order they answer a route.
    ///   - onShutdown: Runs when the client is shut down, for example to check that a test
    ///     shuts it down (default: `nil`).
    public init(
        stubs: [HTTPStub],
        onShutdown: (@Sendable () async throws -> Void)? = nil
    ) {
        self.stubsBox = NIOLockedValueBox(stubs)
        self.callCounts = NIOLockedValueBox([:])
        self.onShutdown = NIOLockedValueBox(onShutdown)
        self.received = NIOLockedValueBox([])
    }

    /// Every request this transport received, oldest first, including ones no stub matched.
    ///
    /// Requests answered by the cache never reach the transport, so they are not here. Request
    /// bodies cannot be read back from `HTTPClientRequest`. Check them in a stub's
    /// `requestValidator` or in a middleware instead.
    public var requests: [HTTPClientRequest] {
        received.withLockedValue { $0 }
    }
}

extension MockHTTPClient: HTTPTransport {
    /// Records `request` and answers it from the next matching stub, after its validator and
    /// delay.
    ///
    /// - Parameters:
    ///   - request: The request to answer.
    ///   - timeout: Ignored. A stub's delay is not cut short by it.
    ///   - logger: Ignored.
    /// - Returns: The stub's response, with its whole body.
    /// - Throws: An `invalidRequest` when no stub matches, the stub's error, or the error its
    ///   validator throws.
    public func execute(
        _ request: HTTPClientRequest,
        timeout: TimeAmount,
        logger: Logger? = nil
    ) async throws -> HTTPClientResponse {
        received.withLockedValue { $0.append(request) }
        let key = "[\(request.method.rawValue)]\(request.url)"

        let currentCallCount = callCounts.withLockedValue { counts in
            let nextCount = (counts[key] ?? 0) + 1
            counts[key] = nextCount
            return nextCount
        }

        let currentStubs = stubsBox.withLockedValue { $0 }

        let matches = currentStubs.filter {
            $0.method == request.method && $0.urlMatcher(request.url)
        }

        guard !matches.isEmpty else {
            // A missing stub is a mistake in the test, not a network failure, so it is never retried
            throw NetSkeinError.custom(
                kind: .invalidRequest,
                message: """
                    No HTTPStub matches \(request.method.rawValue) \(request.url). Add one, for example \
                    HTTPStub.request(.\(request.method.rawValue), url: "\(request.url)")
                    """
            )
        }

        // Each call to a route uses the next matching stub. Calls beyond them reuse the last one
        let matchingStub = matches[min(currentCallCount, matches.count) - 1]

        if let validator = matchingStub.requestValidator {
            try validator(request)
        }

        if let delay = matchingStub.delay {
            try await Task.sleep(nanoseconds: UInt64(delay.nanoseconds))
        }

        switch matchingStub.outcome {
        case let .response(status, headers, body):
            let bodyBuffer = body ?? ByteBuffer()
            return HTTPClientResponse(
                status: status,
                headers: headers,
                body: .bytes(bodyBuffer)
            )

        case let .error(error):
            throw error
        }
    }

    /// Runs the `onShutdown` closure passed to ``init(stubs:onShutdown:)``, if any.
    ///
    /// - Throws: The error the closure throws.
    public func shutdown() async throws {
        if let closure = onShutdown.withLockedValue({ $0 }) {
            try await closure()
        }
    }
}
