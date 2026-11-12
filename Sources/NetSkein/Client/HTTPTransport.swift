import AsyncHTTPClient
import Logging
import NIOCore

/// The connection layer a ``NetSkeinClient`` sends requests through.
///
/// AsyncHTTPClient's `HTTPClient` conforms, and it's what ``NetSkeinClientBuilder`` creates.
/// Conform your own type to replace the network, for example with canned responses in tests.
/// The `NetSkeinTesting` library provides one. Pass it to
/// ``NetSkeinClient/init(transport:defaultHeaders:cookieJar:cache:circuitBreaker:transportDecompresses:retryPolicy:callTimeout:attemptMiddlewares:callMiddlewares:tracer:logger:percentEncoder:)``.
public protocol HTTPTransport: Sendable {
    /// Sends `request` and returns the response once its headers arrive, with the body still
    /// to be read.
    ///
    /// - Parameters:
    ///   - request: The request to send, after middleware has run.
    ///   - timeout: How long to wait for the response headers.
    ///   - logger: The logger for this request, tagged with its request ID.
    /// - Returns: The response, with its body still to be read.
    /// - Throws: Any error when no response arrives. Errors other than ``NetSkeinError`` are
    ///   reported to the caller as ``NetSkeinError/Kind/networkFailure``.
    func execute(
        _ request: HTTPClientRequest,
        timeout: TimeAmount,
        logger: Logger?
    ) async throws -> HTTPClientResponse

    /// Closes connections and releases resources. Called by ``NetSkeinClient/shutdown()``.
    func shutdown() async throws
}

extension HTTPClient: HTTPTransport {}
