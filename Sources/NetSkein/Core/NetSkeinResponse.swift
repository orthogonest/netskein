import AsyncHTTPClient
import NIOCore
import NIOHTTP1

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public struct NetSkeinResponse: Sendable {
    public let status: HTTPResponseStatus
    public let headers: HTTPHeaders
    private let body: ByteBuffer?

    public init(underlyingResponse: HTTPClientResponse, maxBytes: Int) async throws {
        self.status = underlyingResponse.status
        self.headers = underlyingResponse.headers

        do {
            let collectedBytes = try await underlyingResponse.body.collect(upTo: maxBytes)
            self.body = collectedBytes.readableBytes > 0 ? collectedBytes : nil
        } catch {
            throw NetSkeinError.custom(
                kind: .networkFailure,
                message: "Failed to collect response body sequence: \(error.localizedDescription)",
                underlyingError: error
            )
        }
    }
}

extension NetSkeinResponse {
    @discardableResult
    public func errorForStatus() throws(NetSkeinError) -> Self {
        guard status.code >= 200 && status.code < 300 else { throw .badStatus(status) }
        return self
    }

    public func bytes(upTo maxLength: Int? = nil) -> ByteBuffer? {
        guard let body else { return nil }
        if let maxLength, body.readableBytes > maxLength {
            return body.getSlice(at: body.readerIndex, length: maxLength)
        }
        return body
    }

    public func text(upTo maxLength: Int? = nil) -> String? {
        guard let body = bytes(upTo: maxLength) else { return nil }
        return body.getString(at: body.readerIndex, length: body.readableBytes)
    }

    public func json<T: Decodable>(
        _: T.Type,
        decoder: JSONDecoder = JSONDecoder()
    ) throws(NetSkeinError) -> T {
        guard let body = bytes() else { throw .simple(.emptyResponseBody) }

        do {
            return try decoder.decode(T.self, from: body)
        } catch {
            throw .custom(
                kind: .invalidPayload,
                message: "Failed to decode JSON payload: \(error.localizedDescription)",
                underlyingError: error
            )
        }
    }
}
