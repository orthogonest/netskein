import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

public final class RequestBuilder {
    private let client: NetGlideClient
    private var method: HTTPMethod
    private var url: String
    private var headers: HTTPHeaders
    private var body: HTTPClient.Body?

    public init(
        client: NetGlideClient,
        method: HTTPMethod,
        url: String
    ) {
        self.client = client
        self.method = method
        self.url = url
        headers = client.defaultHeaders
    }

    @discardableResult
    public func header(_ name: String, _ value: String) -> Self {
        headers.add(name: name, value: value)
        return self
    }

    @discardableResult
    public func json(_ bodyObject: some Encodable) throws -> Self {
        let data = try JSONEncoder().encode(bodyObject)
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        body = .byteBuffer(buffer)
        headers.add(name: "Content-Type", value: "application/json")
        return self
    }

    @discardableResult
    public func query(_ items: [String: String]) -> Self {
        guard var components = URLComponents(string: url) else { return self }

        var queryItems = components.queryItems ?? []
        for (key, value) in items {
            queryItems.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = queryItems

        if let updatedURL = components.url?.absoluteString {
            url = updatedURL
        }

        return self
    }

    public func send() async throws -> NetGlideResponse {
        let request = try HTTPClient.Request(
            url: url,
            method: method,
            headers: headers,
            body: body
        )
        let response = try await client.underlyingClient.execute(request: request).get()
        return NetGlideResponse(underlyingResponse: response)
    }
}
