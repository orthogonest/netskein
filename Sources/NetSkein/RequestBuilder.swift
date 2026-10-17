#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

import AsyncHTTPClient
import NIOCore
import NIOHTTP1

public final class RequestBuilder {
    private let client: NetSkeinClient
    private var method: HTTPMethod
    private var url: String
    private var headers: HTTPHeaders
    private var body: HTTPClient.Body?
    private var timeout: TimeAmount?
    private let fileManager: FileManager

    public init(
        client: NetSkeinClient,
        method: HTTPMethod,
        url: String
    ) {
        self.client = client
        self.method = method
        self.url = url
        headers = client.defaultHeaders
        fileManager = .default
    }
}

extension RequestBuilder {
    private func getCookie() -> String? {
        guard let jar = client.cookieJar,
              let urlObject = URL(string: url),
              let host = urlObject.host,
              let cookieValue = jar.cookieHeader(for: host) else { return nil }
        return cookieValue
    }

    private func setCookie(cookieHeaders: [String]) {
        guard let jar = client.cookieJar,
              let urlObject = URL(string: url),
              let host = urlObject.host else { return }

        for cookie in cookieHeaders {
            let components = cookie.components(separatedBy: ";")
            guard let parts = components.first?.components(separatedBy: "="), parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            jar.setCookie(host: host, name: name, value: value)
        }
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
    func form(_ fields: [String: String]) -> Self {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let queryString = components.query ?? components.percentEncodedQuery else { return self }

        let data = Data(queryString.utf8)
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)

        body = .byteBuffer(buffer)
        headers.replaceOrAdd(name: "Content-Type", value: "application/x-www-form-urlencoded")

        return self
    }

    @discardableResult
    func timeout(_ duration: TimeAmount) -> Self {
        timeout = duration
        return self
    }

    @discardableResult
    func multipart(_ form: NetSkeinMultipartForm) -> Self {
        let boundary = form.boundary

        var multipartBuffer = ByteBufferAllocator().buffer(capacity: form.estimatedLength)

        for part in form.parts {
            multipartBuffer.writeString("--\(boundary)\r\n")

            if let filename = part.filename {
                multipartBuffer.writeString("Content-Disposition: form-data; name=\"\(part.name)\"; filename=\"\(filename)\"\r\n")
            } else {
                multipartBuffer.writeString("Content-Disposition: form-data; name=\"\(part.name)\"\r\n")
            }

            if let contentType = part.contentType {
                multipartBuffer.writeString("Content-Type: \(contentType)\r\n")
            }

            multipartBuffer.writeString("\r\n")

            var partBody = part.body
            multipartBuffer.writeBuffer(&partBody)

            multipartBuffer.writeString("\r\n")
        }

        multipartBuffer.writeString("--\(boundary)--\r\n")

        body = .byteBuffer(multipartBuffer)
        headers.replaceOrAdd(name: "Content-Type", value: "multipart/form-data; boundary=\(boundary)")

        return self
    }

    @discardableResult
    func stream(fileAtPath path: String, chunkSize: Int = 64 * 1024) -> Self {
        let eventLoop = client.underlyingClient.eventLoopGroup.next()

        guard let fileHandle = FileHandle(forReadingAtPath: path) else {
            body = .stream { _ in
                eventLoop.makeFailedFuture(NetSkeinError.fileNotFound(path))
            }
            return self
        }

        let streamer = ChunkStreamer(
            fileHandle: fileHandle,
            chunkSize: chunkSize,
            eventLoop: eventLoop
        )

        body = .stream { streamer.readAndWrite(using: $0) }

        headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
        headers.replaceOrAdd(name: "Content-Type", value: "application/octet-stream")

        return self
    }

    func send() async throws -> NetSkeinResponse {
        let requestID = UUID().uuidString
        headers.replaceOrAdd(name: "X-Request-ID", value: requestID)

        var clientLogger = client.logger
        clientLogger[metadataKey: "request_id"] = .string(requestID)
        clientLogger[metadataKey: "http_method"] = .string(method.rawValue)
        clientLogger[metadataKey: "url"] = .string(url)

        clientLogger.info("Initiating outbound network request")

        if let cookieValue = getCookie() {
            headers.replaceOrAdd(name: "Cookie", value: cookieValue)
        }

        let request = try HTTPClient.Request(url: url, method: method, headers: headers, body: body)
        let deadline = timeout.map { NIODeadline.now() + $0 }
        let startTime = DispatchTime.now()

        do {
            let response = try await client.underlyingClient.execute(request: request, deadline: deadline).get()

            let endTime = DispatchTime.now()
            let duration = Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / NanoSeconds.toSeconds
            let activeResponseID = response.headers["X-Request-ID"].first ?? requestID

            clientLogger.info("Request completed successfully", metadata: [
                "request_id": .string(activeResponseID),
                "status_code": .string("\(response.status.code)"),
                "duration_seconds": .string(String(format: "%.4f", duration)),
            ])

            let cookieHeaders = response.headers["Set-Cookie"]
            setCookie(cookieHeaders: cookieHeaders)

            return NetSkeinResponse(underlyingResponse: response)
        } catch {
            clientLogger.error("Network request failed", metadata: [
                "request_id": .string(requestID),
                "error_description": .string(error.localizedDescription),
            ])
            throw error
        }
    }

    func download(toFileAtPath path: String) async throws {
        let requestID = UUID().uuidString
        headers.replaceOrAdd(name: "X-Request-ID", value: requestID)

        var clientLogger = client.logger
        clientLogger[metadataKey: "request_id"] = .string(requestID)
        clientLogger[metadataKey: "http_method"] = .string(method.rawValue)
        clientLogger[metadataKey: "url"] = .string(url)

        clientLogger.info("Initiating outbound streaming download request")

        if let cookieValue = getCookie() {
            headers.replaceOrAdd(name: "Cookie", value: cookieValue)
        }

        fileManager.createFile(atPath: path, contents: nil)
        guard let fileHandle = FileHandle(forWritingAtPath: path) else {
            throw NetSkeinError.fileNotFound(path)
        }

        let request = try HTTPClient.Request(url: url, method: method, headers: headers, body: body)
        let deadline = timeout.map { NIODeadline.now() + $0 }
        let eventLoop = client.underlyingClient.eventLoopGroup.next()
        let startTime = DispatchTime.now()

        let delegate = NetSkeinDownloadDelegate(fileHandle: fileHandle, eventLoop: eventLoop)

        do {
            let task = client.underlyingClient.execute(
                request: request,
                delegate: delegate,
                eventLoop: .indifferent,
                deadline: deadline,
                logger: client.logger
            )

            let responseHead = try await task.futureResult.get()

            let endTime = DispatchTime.now()
            let duration = Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / NanoSeconds.toSeconds
            let activeResponseID = responseHead.headers["X-Request-ID"].first ?? requestID

            clientLogger.info("Streaming download completed successfully", metadata: [
                "request_id": .string(activeResponseID),
                "status_code": .string("\(responseHead.status.code)"),
                "duration_seconds": .string(String(format: "%.4f", duration)),
            ])

            let cookieHeaders = responseHead.headers["Set-Cookie"]
            setCookie(cookieHeaders: cookieHeaders)
        } catch {
            clientLogger.error("Streaming download request failed", metadata: [
                "request_id": .string(requestID),
                "error_description": .string(error.localizedDescription),
            ])
            throw error
        }
    }
}
