import AsyncHTTPClient
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NetSkein

public final class MockHTTPClient: Sendable {
    let stubsBox: NIOLockedValueBox<[HTTPStub]>
    let callCounts: NIOLockedValueBox<[String: Int]>
    let onShutdown: NIOLockedValueBox<(@Sendable () async throws -> Void)?>

    public init(
        stubs: [HTTPStub],
        onShutdown: (@Sendable () async throws -> Void)? = nil
    ) {
        self.stubsBox = NIOLockedValueBox(stubs)
        self.callCounts = NIOLockedValueBox([:])
        self.onShutdown = NIOLockedValueBox(onShutdown)
    }
}

extension MockHTTPClient: HTTPTransport {
    public func execute(
        _ request: HTTPClientRequest,
        timeout: TimeAmount,
        logger: Logger? = nil
    ) async throws -> HTTPClientResponse {
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
            throw NetSkeinError.custom(
                kind: .networkFailure,
                message: "Unhandled request caught for route \(key)"
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
