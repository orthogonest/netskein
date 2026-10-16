import AsyncHTTPClient
import Foundation
import NIOHTTP1

public struct NetGlideResponse {
    let underlyingResponse: HTTPClient.Response

    public init(underlyingResponse: HTTPClient.Response) {
        self.underlyingResponse = underlyingResponse
    }

    public var status: HTTPResponseStatus {
        underlyingResponse.status
    }

    @discardableResult
    public func errorForStatus() throws -> Self {
        if status.code < 200 || status.code >= 299 {
            throw NetGlideError.badStatus(status)
        }
        return self
    }

    public func text() -> String? {
        guard var body = underlyingResponse.body else { return nil }
        return body.readString(length: body.readableBytes)
    }

    public func json<T: Decodable>(_: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        guard var body = underlyingResponse.body,
              let data = body.readData(length: body.readableBytes)
        else {
            throw NetGlideError.emptyResponseBody
        }

        return try decoder.decode(T.self, from: data)
    }
}
