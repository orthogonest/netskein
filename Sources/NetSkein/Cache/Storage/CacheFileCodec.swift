import Foundation
import NIOCore
import NIOHTTP1

/// The binary format of one ``DiskCacheStorage`` file: every entry stored for one URL.
///
/// ```
/// magic "NSCF" · format version · URL · entry count · entries…
/// entry: status code · reason · headers · body · varying request headers ·
///        request time · response time · forced flag
/// ```
///
/// Integers are big-endian; strings, bodies and header lists are prefixed with their length.
/// Times are stored as the bit pattern of their seconds since 1970.
enum CacheFileCodec {
    /// Changes whenever the format does; files with another version are discarded.
    static let version: UInt8 = 1

    /// `"NSCF"` (NetSkein Cache File), so a file that is not a NetSkein cache file is never misread as one.
    private static let magic: UInt32 = 0x4E53_4346

    static func encode(_ entries: [CachedResponse], url: String) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(magic)
        buffer.writeInteger(version)
        buffer.writeLengthPrefixed(url)
        buffer.writeInteger(UInt32(entries.count))

        for entry in entries {
            buffer.writeInteger(UInt16(entry.status.code))
            buffer.writeLengthPrefixed(entry.status.reasonPhrase)
            buffer.writeHeaders(entry.headers)
            var body = entry.body
            buffer.writeInteger(UInt32(body.readableBytes))
            buffer.writeBuffer(&body)
            buffer.writeHeaders(entry.varyingRequestHeaders)
            buffer.writeInteger(entry.requestTime.timeIntervalSince1970.bitPattern)
            buffer.writeInteger(entry.responseTime.timeIntervalSince1970.bitPattern)
            buffer.writeInteger(UInt8(entry.isForced ? 1 : 0))
        }

        return buffer
    }

    /// The entries in `buffer`, or `nil` when it is not a complete file of this version.
    static func decode(_ buffer: ByteBuffer) -> (url: String, entries: [CachedResponse])? {
        var buffer = buffer

        guard
            buffer.readInteger(as: UInt32.self) == magic,
            buffer.readInteger(as: UInt8.self) == version,
            let url = buffer.readLengthPrefixedString(),
            let count = buffer.readInteger(as: UInt32.self)
        else { return nil }

        var entries: [CachedResponse] = []
        for _ in 0..<count {
            guard let entry = buffer.readEntry() else { return nil }
            entries.append(entry)
        }

        // Trailing bytes mean the file is not what this version wrote
        guard buffer.readableBytes == 0 else { return nil }
        return (url, entries)
    }
}

extension ByteBuffer {
    fileprivate mutating func writeLengthPrefixed(_ string: String) {
        writeInteger(UInt32(string.utf8.count))
        writeString(string)
    }

    fileprivate mutating func readLengthPrefixedString() -> String? {
        guard let length = readInteger(as: UInt32.self) else { return nil }
        return readString(length: Int(length))
    }

    fileprivate mutating func writeHeaders(_ headers: HTTPHeaders) {
        writeInteger(UInt32(headers.count))
        for (name, value) in headers {
            writeLengthPrefixed(name)
            writeLengthPrefixed(value)
        }
    }

    fileprivate mutating func readHeaders() -> HTTPHeaders? {
        guard let count = readInteger(as: UInt32.self) else { return nil }

        var headers = HTTPHeaders()
        for _ in 0..<count {
            guard
                let name = readLengthPrefixedString(),
                let value = readLengthPrefixedString()
            else { return nil }
            headers.add(name: name, value: value)
        }
        return headers
    }

    fileprivate mutating func readTime() -> Date? {
        readInteger(as: UInt64.self).map { Date(timeIntervalSince1970: Double(bitPattern: $0)) }
    }

    fileprivate mutating func readEntry() -> CachedResponse? {
        guard
            let code = readInteger(as: UInt16.self),
            let reason = readLengthPrefixedString(),
            let headers = readHeaders(),
            let bodyLength = readInteger(as: UInt32.self),
            let body = readSlice(length: Int(bodyLength)),
            let varying = readHeaders(),
            let requestTime = readTime(),
            let responseTime = readTime(),
            let forced = readInteger(as: UInt8.self)
        else { return nil }

        return CachedResponse(
            status: HTTPResponseStatus(statusCode: Int(code), reasonPhrase: reason),
            headers: headers,
            body: body,
            varyingRequestHeaders: varying,
            requestTime: requestTime,
            responseTime: responseTime,
            isForced: forced == 1
        )
    }
}
