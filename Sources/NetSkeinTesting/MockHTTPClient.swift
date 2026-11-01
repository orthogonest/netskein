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
/// last stub keep getting the last one. A request without a matching stub fails with a
/// `clientError` naming the request, so a missing stub is reported once, never retried as a
/// network failure.
public final class MockHTTPClient: Sendable {
    let stubsBox: NIOLockedValueBox<[HTTPStub]>
    let callCounts: NIOLockedValueBox<[String: Int]>
    let onShutdown: NIOLockedValueBox<(@Sendable () async throws -> Void)?>
    private let received: NIOLockedValueBox<[HTTPClientRequest]>

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
    /// bodies cannot be read back from `HTTPClientRequest`; check them in a stub's
    /// `requestValidator` or in a middleware instead.
    public var requests: [HTTPClientRequest] {
        received.withLockedValue { $0 }
    }
}

extension MockHTTPClient: HTTPTransport {
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
                kind: .clientError,
                message: """
                    No HTTPStub matches \(request.method.rawValue) \(request.url); add one, for example \
                    HTTPStub.request(.\(request.method.rawValue), url: "\(request.url)")
                    """
            )
        }

        // Each call to a route uses the next matching stub; calls beyond them reuse the last one
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

    public func shutdown() async throws {
        if let closure = onShutdown.withLockedValue({ $0 }) {
            try await closure()
        }
    }
}
