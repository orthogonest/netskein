import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

public struct NetGlideResponse {
    private let underlyingResponse: HTTPClient.Response

    public init(underlyingResponse: HTTPClient.Response) {
        self.underlyingResponse = underlyingResponse
    }
}

public extension NetGlideResponse {
    var status: HTTPResponseStatus {
        underlyingResponse.status
    }

    @discardableResult
    func errorForStatus() throws -> Self {
        if status.code < 200 || status.code >= 299 {
            throw NetGlideError.badStatus(status)
        }
        return self
    }

    func bytes() -> ByteBuffer? {
        underlyingResponse.body
    }

    func text() -> String? {
        guard var body = bytes() else { return nil }
        return body.readString(length: body.readableBytes)
    }

    func json<T: Decodable>(_: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        guard var body = bytes(),
              let data = body.readData(length: body.readableBytes)
        else {
            throw NetGlideError.emptyResponseBody
        }

        return try decoder.decode(T.self, from: data)
    }
}
