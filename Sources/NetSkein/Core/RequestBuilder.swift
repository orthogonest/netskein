import AsyncHTTPClient
import NIOCore
import NIOHTTP1

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public protocol HTTPMethodRequest: Sendable {}
public protocol HTTPMethodWithBody: HTTPMethodRequest {}

public struct GETRequest: HTTPMethodRequest {}
public struct POSTRequest: HTTPMethodRequest, HTTPMethodWithBody {}
public struct PUTRequest: HTTPMethodRequest, HTTPMethodWithBody {}
public struct PATCHRequest: HTTPMethodRequest, HTTPMethodWithBody {}
public struct DELETERequest: HTTPMethodRequest {}

public struct RequestBuilder<Method: HTTPMethodRequest> {
    private let client: NetSkeinClient
    private var method: HTTPMethod
    private var url: String
    private var headers: HTTPHeaders
    private var body: HTTPClientRequest.Body?
    private var maxResponseBytes: Int
    private var timeout: TimeAmount?
    private let fileManager: FileManager

    public init(
        client: NetSkeinClient,
        method: HTTPMethod,
        url: String,
        maxResponseBytes: Int = 10 * 1024 * 1024
    ) {
        self.client = client
        self.method = method
        self.url = url
        self.maxResponseBytes = maxResponseBytes
        headers = client.defaultHeaders
        fileManager = .default
    }
}

extension RequestBuilder {
    private func getCookie() -> String? {
        guard let jar = client.cookieJar,
            let urlObject = URL(string: url),
            let host = urlObject.host,
            let cookieValue = jar.cookieHeader(for: host)
        else { return nil }
        return cookieValue
    }

    private func setCookie(cookieHeaders: [String]) {
        guard let jar = client.cookieJar,
            let urlObject = URL(string: url),
            let host = urlObject.host
        else { return }

        for cookie in cookieHeaders {
            let components = cookie.components(separatedBy: ";")
            guard let parts = components.first?.components(separatedBy: "="), parts.count == 2
            else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            jar.setCookie(host: host, name: name, value: value)
        }
    }
}

extension RequestBuilder {
    @discardableResult
    public func header(_ name: String, _ value: String) -> Self {
        var copy = self
        copy.headers.add(name: name, value: value)
        return copy
    }

    @discardableResult
    public func query(_ items: [String: String]) -> Self {
        guard var components = URLComponents(string: url) else { return self }

        var queryItems = components.queryItems ?? []
        for (key, value) in items { queryItems.append(URLQueryItem(name: key, value: value)) }
        components.queryItems = queryItems

        var copy = self

        if let updatedURL = components.url?.absoluteString { copy.url = updatedURL }

        return copy
    }

    @discardableResult
    public func maxResponseSize(_ bytes: Int) -> Self {
        var copy = self
        copy.maxResponseBytes = bytes
        return copy
    }

    @discardableResult
    public func timeout(_ duration: TimeAmount) -> Self {
        var copy = self
        copy.timeout = duration
        return copy
    }
}

extension RequestBuilder where Method: HTTPMethodWithBody {
    @discardableResult
    public func json(_ bodyObject: some Encodable) throws(NetSkeinError) -> Self {
        do {
            let data = try JSONEncoder().encode(bodyObject)
            let allocator = ByteBufferAllocator()
            var buffer = allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)

            var copy = self
            copy.body = .bytes(buffer)
            copy.headers.add(name: "Content-Type", value: "application/json")
            return copy
        } catch {
            throw .custom(
                kind: .invalidPayload,
                message: "Failed to decode JSON request: \(error.localizedDescription)",
                underlyingError: error
            )
        }
    }

    @discardableResult
    public func form(_ fields: [String: String]) -> Self {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let queryString = components.query ?? components.percentEncodedQuery else {
            return self
        }

        let data = Data(queryString.utf8)
        let allocator = ByteBufferAllocator()
        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)

        var copy = self
        copy.body = .bytes(buffer)
        copy.headers.replaceOrAdd(name: "Content-Type", value: "application/x-www-form-urlencoded")

        return copy
    }

    @discardableResult
    public func multipart(_ form: NetSkeinMultipartForm) -> Self {
        let boundary = form.boundary

        let allocator = ByteBufferAllocator()
        var multipartBuffer = allocator.buffer(capacity: form.estimatedLength)

        for part in form.parts {
            multipartBuffer.writeString("--\(boundary)\r\n")

            if let filename = part.filename {
                multipartBuffer.writeString(
                    "Content-Disposition: form-data; name=\"\(part.name)\"; filename=\"\(filename)\"\r\n"
                )
            } else {
                multipartBuffer.writeString(
                    "Content-Disposition: form-data; name=\"\(part.name)\"\r\n"
                )
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

        var copy = self
        copy.body = .bytes(multipartBuffer)
        copy.headers.replaceOrAdd(
            name: "Content-Type",
            value: "multipart/form-data; boundary=\(boundary)"
        )

        return copy
    }

    @discardableResult
    public func stream(fileAtPath path: String, chunkSize: Int = 64 * 1024) -> Self {
        var copy = self

        guard let fileHandle = FileHandle(forReadingAtPath: path),
            let fileAttributes = try? fileManager.attributesOfItem(atPath: path),
            let fileSize = fileAttributes[.size] as? Int64
        else {
            copy.body = .stream(AsyncStream<UInt8> { $0.finish() }, length: .unknown)
            return self
        }

        copy.body = .stream(fileHandle.bytes, length: .known(fileSize))
        copy.headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
        copy.headers.replaceOrAdd(name: "Content-Type", value: "application/octet-stream")

        return copy
    }
}

extension RequestBuilder {
    public func send() async throws(NetSkeinError) -> NetSkeinResponse {
        var activeHeaders = headers

        let requestID = UUID().uuidString
        activeHeaders.replaceOrAdd(name: "X-Request-ID", value: requestID)

        var clientLogger = client.logger
        clientLogger[metadataKey: "request_id"] = .string(requestID)
        clientLogger[metadataKey: "http_method"] = .string(method.rawValue)
        clientLogger[metadataKey: "url"] = .string(url)

        clientLogger.info("Initiating outbound network request")

        if let cookieValue = getCookie() {
            activeHeaders.replaceOrAdd(name: "Cookie", value: cookieValue)
        }

        var request = HTTPClientRequest(url: url)
        request.method = method
        request.headers = activeHeaders
        request.body = body

        let startTime = DispatchTime.now()

        do {
            let response = try await client.underlyingClient
                .execute(request, timeout: timeout ?? .seconds(30), logger: clientLogger)

            let endTime = DispatchTime.now()
            let duration =
                Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds)
                / NanoSeconds.toSeconds
            let activeResponseID = response.headers["X-Request-ID"].first ?? requestID

            clientLogger.info(
                "Request completed successfully",
                metadata: [
                    "request_id": .string(activeResponseID),
                    "status_code": .string("\(response.status.code)"),
                    "duration_seconds": .string(String(format: "%.4f", duration)),
                ]
            )

            let cookieHeaders = response.headers["Set-Cookie"]
            setCookie(cookieHeaders: cookieHeaders)

            return try await NetSkeinResponse(
                underlyingResponse: response,
                maxBytes: maxResponseBytes
            )
        } catch let error as NetSkeinError {
            throw error
        } catch {
            clientLogger.error(
                "Network request failed",
                metadata: [
                    "request_id": .string(requestID),
                    "error_description": .string(error.localizedDescription),
                ]
            )
            throw .custom(
                kind: .networkFailure,
                message: "Network execution failed: \(error.localizedDescription)",
                underlyingError: error
            )
        }
    }

    public func send(
        _ onChunk: @Sendable (ByteBuffer, _ progress: Double?) async throws -> Void
    ) async throws(NetSkeinError) {
        var activeHeaders = headers

        let requestID = UUID().uuidString
        activeHeaders.replaceOrAdd(name: "X-Request-ID", value: requestID)

        var clientLogger = client.logger
        clientLogger[metadataKey: "request_id"] = .string(requestID)
        clientLogger[metadataKey: "http_method"] = .string(method.rawValue)
        clientLogger[metadataKey: "url"] = .string(url)

        clientLogger.info("Initiating outbound streaming download request")

        if let cookieValue = getCookie() {
            activeHeaders.replaceOrAdd(name: "Cookie", value: cookieValue)
        }

        var request = HTTPClientRequest(url: url)
        request.method = method
        request.headers = activeHeaders
        request.body = body

        let startTime = DispatchTime.now()

        do {
            let response = try await client.underlyingClient.execute(
                request,
                timeout: timeout ?? .seconds(30),
                logger: clientLogger
            )

            let endTime = DispatchTime.now()
            let duration =
                Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds)
                / NanoSeconds.toSeconds
            let activeResponseID = response.headers["X-Request-ID"].first ?? requestID

            clientLogger.info(
                "Streaming response head received successfully",
                metadata: [
                    "request_id": .string(activeResponseID),
                    "status_code": .string("\(response.status.code)"),
                    "duration_seconds": .string(String(format: "%.4f", duration)),
                ]
            )

            let cookieHeaders = response.headers["Set-Cookie"]
            setCookie(cookieHeaders: cookieHeaders)

            let expectedBytes = response.headers.first(name: "content-length").flatMap(Int.init)
            var receivedBytes = 0

            for try await buffer in response.body {
                receivedBytes += buffer.readableBytes
                let progress: Double? = expectedBytes.map { Double(receivedBytes) / Double($0) }
                try await onChunk(buffer, progress)
            }

            clientLogger.info(
                "Finished streaming response body. Total bytes received: \(receivedBytes)"
            )
        } catch let error as NetSkeinError {
            throw error
        } catch {
            clientLogger.error(
                "Streaming network request execution failed",
                metadata: [
                    "request_id": .string(requestID),
                    "error_description": .string(error.localizedDescription),
                ]
            )
            throw .custom(
                kind: .networkFailure,
                message: "Streaming network execution failed: \(error.localizedDescription)",
                underlyingError: error
            )
        }
    }

    public func download(
        toFileAtPath path: String,
        onProgress: (@Sendable (_ bytesReceived: Int64, _ bytesTotal: Int64?) -> Void)? = nil
    ) async throws(NetSkeinError) {
        var activeHeaders = headers

        let requestID = UUID().uuidString
        activeHeaders.replaceOrAdd(name: "X-Request-ID", value: requestID)

        var clientLogger = client.logger
        clientLogger[metadataKey: "request_id"] = .string(requestID)
        clientLogger[metadataKey: "http_method"] = .string(method.rawValue)
        clientLogger[metadataKey: "url"] = .string(url)

        clientLogger.info("Initiating outbound streaming download request")

        if let cookieValue = getCookie() {
            activeHeaders.replaceOrAdd(name: "Cookie", value: cookieValue)
        }

        guard fileManager.createFile(atPath: path, contents: nil),
            let fileHandle = FileHandle(forWritingAtPath: path)
        else {
            throw .custom(
                kind: .ioFailure,
                message: "File could not be created or written to at the specified path: \(path)."
            )
        }

        var request = HTTPClientRequest(url: url)
        request.method = method
        request.headers = activeHeaders
        request.body = body

        let startTime = DispatchTime.now()

        do {
            let response = try await client.underlyingClient.execute(
                request,
                timeout: timeout ?? .seconds(30),
                logger: clientLogger
            )

            let endTime = DispatchTime.now()
            let duration =
                Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds)
                / NanoSeconds.toSeconds
            let activeResponseID = response.headers["X-Request-ID"].first ?? requestID

            clientLogger.info(
                "Streaming download completed successfully",
                metadata: [
                    "request_id": .string(activeResponseID),
                    "status_code": .string("\(response.status.code)"),
                    "duration_seconds": .string(String(format: "%.4f", duration)),
                ]
            )

            guard response.status.code >= 200 && response.status.code < 300 else {
                try? fileHandle.close()
                throw NetSkeinError.badStatus(response.status)
            }

            let cookieHeaders = response.headers["Set-Cookie"]
            setCookie(cookieHeaders: cookieHeaders)

            let expectedBytes = response.headers.first(name: "content-length").flatMap(Int64.init)
            var receivedBytes: Int64 = 0

            for try await buffer in response.body {
                let currentChunkSize = Int64(buffer.readableBytes)

                try buffer.withUnsafeReadableBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else { return }
                    let data = Data(
                        bytesNoCopy: UnsafeMutableRawPointer(mutating: baseAddress),
                        count: bytes.count,
                        deallocator: .none
                    )
                    try fileHandle.write(contentsOf: data)
                }

                receivedBytes += currentChunkSize
                onProgress?(receivedBytes, expectedBytes)
            }

            try fileHandle.close()

            clientLogger.info(
                "Streaming download completed successfully. Total bytes written: \(receivedBytes)"
            )
        } catch let error as NetSkeinError {
            try? fileHandle.close()
            throw error
        } catch {
            try? fileHandle.close()
            clientLogger.error(
                "Streaming download request failed",
                metadata: [
                    "request_id": .string(requestID),
                    "error_description": .string(error.localizedDescription),
                ]
            )
            throw .custom(
                kind: .networkFailure,
                message: "Streaming download failed: \(error.localizedDescription)",
                underlyingError: error
            )
        }
    }
}
