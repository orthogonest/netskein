import AsyncHTTPClient
import Logging
import NIOCore

public protocol HTTPTransport: Sendable {
    func execute(
        _ request: HTTPClientRequest,
        timeout: TimeAmount,
        logger: Logger?
    ) async throws -> HTTPClientResponse

    func shutdown() async throws
}

extension HTTPClient: HTTPTransport {}
