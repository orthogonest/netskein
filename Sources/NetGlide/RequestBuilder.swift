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
    private var timeout: TimeAmount?

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
}

public extension RequestBuilder {
    @discardableResult
    func header(_ name: String, _ value: String) -> Self {
        headers.add(name: name, value: value)
        return self
    }

    @discardableResult
    func json(_ bodyObject: some Encodable) throws -> Self {
        let data = try JSONEncoder().encode(bodyObject)
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        body = .byteBuffer(buffer)
        headers.add(name: "Content-Type", value: "application/json")
        return self
    }

    @discardableResult
    func query(_ items: [String: String]) -> Self {
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

    @discardableResult
    func timeout(_ duration: TimeAmount) -> Self {
        timeout = duration
        return self
    }

    func send() async throws -> NetGlideResponse {
        if let jar = client.cookieJar,
           let urlObject = URL(string: url),
           let host = urlObject.host,
           let cookieValue = jar.cookieHeader(for: host)
        {
            headers.replaceOrAdd(name: "Cookie", value: cookieValue)
        }

        let request = try HTTPClient.Request(
            url: url,
            method: method,
            headers: headers,
            body: body
        )

        let response: HTTPClient.Response

        if let timeout {
            let deadline = NIODeadline.now() + timeout
            response = try await client.underlyingClient.execute(request: request, deadline: deadline).get()
        } else {
            response = try await client.underlyingClient.execute(request: request).get()
        }

        let result = NetGlideResponse(underlyingResponse: response)

        if let jar = client.cookieJar,
           let urlObject = URL(string: url),
           let host = urlObject.host
        {
            let setCookieHeaders = response.headers["Set-Cookie"]
            for cookie in setCookieHeaders {
                let components = cookie.components(separatedBy: ";")
                guard let parts = components.first?.components(separatedBy: "="),
                      parts.count == 2 else { continue }
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                jar.setCookie(host: host, name: name, value: value)
            }
        }

        return result
    }
}
