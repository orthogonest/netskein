import AsyncHTTPClient
import Foundation
import Logging
import NIOCore

/// Logs each attempt's request as a `curl` command that can be pasted into a terminal.
///
/// The command shows the request as it leaves this middleware, so register it last to log
/// the headers added by the middleware before it. Values of `redactedHeaders` are masked, and
/// in-memory bodies longer than `maxBodyBytes` are truncated. The response is passed through
/// unchanged.
public struct CurlLoggingMiddleware {
    /// How the logged command is laid out.
    public enum Format: Sendable {
        /// The whole command on one line, so log collectors keep it as a single entry.
        case singleLine
        /// One option per line, joined with `\` continuations, for reading in a terminal.
        case multiline
    }

    private let level: Logger.Level
    private let format: Format
    private let redactedHeaders: Set<String>
    private let maxBodyBytes: Int

    public init(
        level: Logger.Level = .debug,
        format: Format = .singleLine,
        redactedHeaders: Set<String> = ["Authorization", "Cookie", "Proxy-Authorization"],
        maxBodyBytes: Int = 1024
    ) {
        self.level = level
        self.format = format
        self.redactedHeaders = Set(redactedHeaders.map { $0.lowercased() })
        self.maxBodyBytes = max(0, maxBodyBytes)
    }
}

extension CurlLoggingMiddleware: HTTPMiddleware {
    public func intercept(
        _ request: RequestHead,
        context: MiddlewareContext,
        next: Next
    ) async throws -> HTTPClientResponse {
        context.logger.log(level: level, "\(command(for: request, body: context.body))")
        return try await next(request)
    }
}

extension CurlLoggingMiddleware {
    package func command(for request: RequestHead, body: RequestBodyDescription) -> String {
        var parts = ["curl -X \(request.method.rawValue) \(quoted(request.url))"]

        for header in request.headers {
            let value =
                redactedHeaders.contains(header.name.lowercased()) ? "<redacted>" : header.value
            parts.append("-H \(quoted("\(header.name): \(value)"))")
        }

        switch body {
        case .none:
            break

        case let .bytes(buffer):
            let shown = String(
                decoding: buffer.readableBytesView.prefix(maxBodyBytes),
                as: UTF8.self
            )
            var data = "--data-binary \(quoted(shown))"
            // The body is always the last option, so this comment never hides a `\` continuation
            if buffer.readableBytes > maxBodyBytes {
                data += " # body truncated to \(maxBodyBytes) of \(buffer.readableBytes) bytes"
            }
            parts.append(data)

        case let .file(path):
            parts.append("--data-binary \(quoted("@\(path)"))")
        }

        switch format {
        case .singleLine: return parts.joined(separator: " ")
        case .multiline: return parts.joined(separator: " \\\n  ")
        }
    }

    /// Wraps `value` in single quotes for a POSIX shell, escaping any single quotes inside it.
    private func quoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: #"'\''"#))'"
    }
}
