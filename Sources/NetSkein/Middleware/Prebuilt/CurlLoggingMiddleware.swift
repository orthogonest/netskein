import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1

/// Logs each attempt's request as a `curl` command that can be pasted into a terminal.
///
/// The command shows the request as it leaves this middleware, so register it last to log
/// the headers added by the middleware before it. Values of `redactedHeaders` are masked, and
/// in-memory bodies longer than `maxBodyBytes` are truncated. The response is passed through
/// unchanged.
///
/// ```swift
/// let client = NetSkeinClient.builder()
///     .using(CurlLoggingMiddleware(format: .multiline))
///     .build()
/// ```
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

    /// Creates a middleware that logs each request as a `curl` command.
    ///
    /// - Parameters:
    ///   - level: The level the command is logged at (default: `debug`).
    ///   - format: How the command is laid out (default: ``Format/singleLine``).
    ///   - redactedHeaders: Headers whose values are replaced with `<redacted>`
    ///     (default: `Authorization`, `Cookie` and `Proxy-Authorization`). Names are
    ///     case-insensitive.
    ///   - maxBodyBytes: The most bytes of an in-memory body shown (default: 1 KiB). Longer
    ///     bodies are truncated. Values below 0 count as 0.
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
    /// Logs `request` as a `curl` command, then sends it on unchanged.
    ///
    /// - Parameters:
    ///   - request: The request to log.
    ///   - context: Provides the logger and the body.
    ///   - next: Sends the request to the rest of the chain.
    /// - Returns: The response, unchanged.
    /// - Throws: Whatever `next` throws.
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
