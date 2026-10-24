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

        let safeIndex = currentCallCount - 1

        let matchingStub: HTTPStub =
            if matches.indices.contains(safeIndex) {
                matches[safeIndex]
            } else if let lastMatch = matches.last {
                lastMatch
            } else {
                throw NetSkeinError.custom(
                    kind: .networkFailure,
                    message: "Unhandled request caught for route \(key)"
                )
            }

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
