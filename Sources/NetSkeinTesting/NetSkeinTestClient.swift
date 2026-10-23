import AsyncHTTPClient
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NetSkein

public final class MockHTTPClient: Sendable {
    let stubsBox: NIOLockedValueBox<[NetSkeinStub]>
    let callCounts: NIOLockedValueBox<[String: Int]>
    let onShutdown: NIOLockedValueBox<(@Sendable () async throws -> Void)?>

    public init(
        stubs: [NetSkeinStub],
        onShutdown: (@Sendable () async throws -> Void)? = nil
    ) {
        self.stubsBox = NIOLockedValueBox(stubs)
        self.callCounts = NIOLockedValueBox([:])
        self.onShutdown = NIOLockedValueBox(onShutdown)
    }
}

extension MockHTTPClient: HTTPClientProtocol {
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

        let matchingStub: NetSkeinStub =
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
        if let closure = onShutdown.withLockedValue({ $0 }) {
            try await closure()
        }
    }
}

public struct NetSkeinTestClientBuilder: Sendable {
    private var defaultHeaders: HTTPHeaders
    private var cookieJar: NetSkeinCookieJar?
    private var logger: Logger
    private var stubs: [NetSkeinStub]
    private var stubOnShutdown: (@Sendable () async throws -> Void)?

    public init() {
        self.stubs = []
        defaultHeaders = HTTPHeaders()
        logger = Logger(label: Label.identifier)
    }
}

extension NetSkeinTestClientBuilder {
    @discardableResult
    public func defaultHeaders(_ headers: HTTPHeaders) -> Self {
        var copy = self
        copy.defaultHeaders = headers
        return copy
    }

    @discardableResult
    public func cookieStore(_ jar: NetSkeinCookieJar) -> Self {
        var copy = self
        copy.cookieJar = jar
        return copy
    }

    @discardableResult
    public func logger(_ logger: Logger) -> Self {
        var copy = self
        copy.logger = logger
        return copy
    }

    @discardableResult
    public func addStubs(_ stubs: [NetSkeinStub]) -> Self {
        var copy = self
        copy.stubs.append(contentsOf: stubs)
        return copy
    }

    @discardableResult
    public func addStub(_ stub: NetSkeinStub) -> Self {
        var copy = self
        copy.stubs.append(stub)
        return copy
    }

    @discardableResult
    public func stubOnShutdown(_ onShutdown: @escaping @Sendable () async throws -> Void) -> Self {
        var copy = self
        copy.stubOnShutdown = onShutdown
        return copy
    }
}

extension NetSkeinTestClientBuilder {
    public func build() -> NetSkeinClient<MockHTTPClient> {
        let client = MockHTTPClient(stubs: stubs, onShutdown: stubOnShutdown)
        return NetSkeinClient(
            underlyingClient: client,
            defaultHeaders: defaultHeaders,
            cookieJar: cookieJar,
            logger: logger
        )
    }
}

extension NetSkeinClient where Client == MockHTTPClient {
    public static func testing() -> NetSkeinTestClientBuilder {
        NetSkeinTestClientBuilder()
    }
}
