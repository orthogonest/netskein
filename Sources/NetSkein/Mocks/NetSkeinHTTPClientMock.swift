import AsyncHTTPClient
import Logging
import NIOConcurrencyHelpers
import NIOCore

public final class NetSkeinHTTPClientMock: HTTPClientProtocol, Sendable {
    private let stubsBox: NIOLockedValueBox<[NetSkeinStub]>
    private let callCounts: NIOLockedValueBox<[String: Int]>
    private let onShutdown: (@Sendable () async throws -> Void)?

    public init(
        stubs: [NetSkeinStub],
        onShutdown: (@Sendable () async throws -> Void)? = nil
    ) {
        self.stubsBox = NIOLockedValueBox(stubs)
        self.callCounts = NIOLockedValueBox([:])
        self.onShutdown = onShutdown
    }

    public func execute(
        _ request: HTTPClientRequest,
        timeout: TimeAmount,
        logger: Logger?
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
                message: "NetSkeinMockEngine: Unhandled request caught for route \(key)"
            )
        }

        let safeIndex = currentCallCount - 1

        let matchingStub: NetSkeinStub =
            if matches.indices.contains(safeIndex) {
                matches[safeIndex]
            } else if let lastMatch = matches.last {
                lastMatch
            } else {
                throw NetSkeinError.custom(
                    kind: .networkFailure,
                    message: "NetSkeinMockEngine: Unhandled request caught for route \(key)"
                )
            }

        if let validator = matchingStub.requestValidator {
            try validator(request)
        }

        if let delay = matchingStub.delay {
            try await Task.sleep(nanoseconds: UInt64(delay.nanoseconds))
        }

        switch matchingStub.outcome {
        case let .success(status, headers, body):
            let bodyBuffer = body ?? ByteBuffer()
            return HTTPClientResponse(
                status: status,
                headers: headers,
                body: .bytes(bodyBuffer)
            )

        case let .failure(error):
            throw error
        }
    }

    public func shutdown() async throws {
        try await onShutdown?()
    }
}
