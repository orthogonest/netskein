import AsyncHTTPClient
import NIOCore
import NIOHTTP1

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public struct NetSkeinResponse: Sendable {
    private let underlyingResponse: HTTPClient.Response

    public init(underlyingResponse: HTTPClient.Response) {
        self.underlyingResponse = underlyingResponse
    }
}

extension NetSkeinResponse {
    public var status: HTTPResponseStatus { underlyingResponse.status }

    public var headers: HTTPHeaders { underlyingResponse.headers }

    @discardableResult
    public func errorForStatus() throws -> Self {
        if status.code < 200 || status.code >= 300 { throw NetSkeinError.badStatus(status) }
        return self
    }

    public func bytes() -> ByteBuffer? { underlyingResponse.body }

    public func text() -> String? {
        guard let body = bytes() else { return nil }
        return body.getString(at: body.readerIndex, length: body.readableBytes)
    }

    public func json<T: Decodable>(_: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        guard let body = bytes(), body.readableBytes > 0 else {
            throw NetSkeinError.emptyResponseBody
        }

        return try decoder.decode(T.self, from: body)
    }
}
