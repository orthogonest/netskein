import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1

/// Writes a successful response to a file, resuming a partial file with `Range` requests
/// when the caller allows it.
struct DownloadOperation {
    let path: String
    let resumption: DownloadResumption
    /// Only `GET` requests can be resumed with `Range`.
    let canResume: Bool
    let onProgress: DownloadProgress?

    /// How much of the file already exists before the current attempt.
    private var existingBytes: Int64 = 0
    /// The strong validator of the bytes on disk, sent as `If-Range` when resuming.
    private var validator: String?

    init(
        path: String,
        resumption: DownloadResumption,
        canResume: Bool,
        onProgress: DownloadProgress?
    ) {
        self.path = path
        self.resumption = resumption
        self.canResume = canResume
        self.onProgress = onProgress
        self.validator = resumption.ifRangeValidator
    }
}

extension DownloadOperation {
    /// Empties a file left by an earlier download unless the caller asked to resume it.
    func discardStaleFile() {
        guard
            resumption == .disabled || resumption == .onRetry,
            FileManager.default.fileExists(atPath: path)
        else { return }
        FileManager.default.createFile(atPath: path, contents: nil)
    }

    private func resumableFileSize() -> Int64 {
        guard
            resumption != .disabled,
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attributes[.size] as? Int64
        else { return 0 }
        return size
    }

    /// Remembers the server's validator and rejects responses that cannot be written.
    private mutating func accept(
        _ response: HTTPClientResponse,
        logger: Logger
    ) throws(NetSkeinError) {
        validator = HTTPValidator(response.headers).ifRange

        // 416 Range Not Satisfiable: start the file over so the retry downloads it in full
        if response.status == .rangeNotSatisfiable {
            logger.warning("416 Range Not Satisfiable received. Truncating file to byte 0.")
            FileManager.default.createFile(atPath: path, contents: nil)
            validator = nil
            throw .badStatus(response.status)
        }

        guard response.status.code >= 200 && response.status.code < 300 else {
            throw .badStatus(response.status)
        }
    }

    /// Writes the body to the file: appending after a `206 Partial Content`, otherwise
    /// starting the file over.
    private func writeBody(
        of response: HTTPClientResponse,
        logger: Logger
    ) async throws(NetSkeinError) {
        let fileHandle: FileHandle
        var receivedBytes: Int64
        let totalExpectedBytes: Int64?

        do {
            // Server accepted Range -> Append to existing bytes
            if response.status == .partialContent {
                guard let handle = FileHandle(forWritingAtPath: path) else {
                    throw NetSkeinError.custom(
                        kind: .ioFailure,
                        message: "Cannot open file handle for append: \(path)"
                    )
                }

                try handle.seekToEnd()
                fileHandle = handle
                receivedBytes = existingBytes

                let contentRange = response.headers.first(name: "Content-Range")
                let parsedTotal = ContentRangeParser.parseTotalBytes(from: contentRange)
                let contentLength = response.headers.first(name: "Content-Length")
                    .flatMap(Int64.init)
                totalExpectedBytes = parsedTotal ?? contentLength.map { $0 + existingBytes }
            }
            // Server returned 200 OK -> Truncate/create fresh from byte 0
            else {
                guard
                    FileManager.default.createFile(atPath: path, contents: nil),
                    let handle = FileHandle(forWritingAtPath: path)
                else {
                    throw NetSkeinError.custom(
                        kind: .ioFailure,
                        message: "Cannot create file at: \(path)"
                    )
                }
                fileHandle = handle
                receivedBytes = 0
                totalExpectedBytes = response.headers.first(name: "Content-Length")
                    .flatMap(Int64.init)
            }
        } catch let error as NetSkeinError {
            throw error
        } catch {
            throw NetSkeinError.custom(
                kind: .ioFailure,
                message:
                    "Filesystem error while preparing download target: \(error.localizedDescription)",
                underlyingError: error
            )
        }

        defer {
            try? fileHandle.close()
        }

        // Stream the body chunks directly to disk
        do {
            for try await buffer in response.body {
                try checkCancellation()
                let chunkSize = Int64(buffer.readableBytes)

                do {
                    try buffer.withUnsafeReadableBytes { bytes in
                        guard let baseAddress = bytes.baseAddress, !bytes.isEmpty else { return }
                        let data = Data(
                            bytesNoCopy: UnsafeMutableRawPointer(mutating: baseAddress),
                            count: bytes.count,
                            deallocator: .none
                        )
                        try fileHandle.write(contentsOf: data)
                    }
                } catch {
                    throw NetSkeinError.custom(
                        kind: .ioFailure,
                        message:
                            "Failed writing chunk to disk at \(path): \(error.localizedDescription)",
                        underlyingError: error
                    )
                }

                receivedBytes += chunkSize
                onProgress?(receivedBytes, totalExpectedBytes)
            }

            logger.info(
                "File download finished successfully. Total bytes: \(receivedBytes)"
            )
        } catch let error as NetSkeinError {
            throw error
        } catch {
            throw NetSkeinError.custom(
                kind: .networkFailure,
                message:
                    "Network connection dropped during file download: \(error.localizedDescription)",
                underlyingError: error
            )
        }
    }
}

extension DownloadOperation: RequestOperation {
    typealias Output = Void

    var name: String { "download" }
    var action: String { "Streaming download" }
    var isBuffered: Bool { false }
    /// A retry rewrites the file or resumes it where it stopped, so nothing is duplicated.
    var hasDeliveredData: Bool { false }

    /// Measures what is already on disk and, when possible, asks only for the missing bytes.
    mutating func prepareAttempt() -> AttemptSetup {
        existingBytes = resumableFileSize()

        guard existingBytes > 0 && canResume else {
            return AttemptSetup(description: "file download")
        }

        var headers: HTTPHeaders = ["Range": "bytes=\(existingBytes)-"]
        if let validator {
            headers.add(name: "If-Range", value: validator)
        }

        return AttemptSetup(
            description: "download resumption from byte \(existingBytes)",
            extraHeaders: headers
        )
    }

    /// Remembers the server's validator, rejects responses that cannot be written, and writes
    /// the rest.
    mutating func handle(_ response: HTTPClientResponse, logger: Logger) async throws -> Output {
        try accept(response, logger: logger)
        try await writeBody(of: response, logger: logger)
    }
}
