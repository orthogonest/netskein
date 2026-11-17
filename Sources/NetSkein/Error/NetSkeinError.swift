import Foundation
import NIOCore
import NIOHTTP1

/// The error every NetSkein request throws.
///
/// Methods declare `throws(NetSkeinError)`, so a `catch` block gets a `NetSkeinError` without
/// casting. Switch on its ``kind`` to decide what to do:
///
/// ```swift
/// do {
///     let user = try await client.get(url).send().validate().json(User.self)
/// } catch {
///     switch error.kind {
///     case .timedOut, .networkFailure:
///         showOfflineBanner()
///     case .clientError:
///         showLoginScreen()
///     default:
///         report(error)
///     }
/// }
/// ```
///
/// `localizedDescription` gives a readable message. When another error caused this one, such as
/// a decoding error, `failureReason` describes it.
///
/// Two errors are equal when they have the same kind and message. The underlying error isn't
/// compared.
///
/// ## Topics
///
/// ### Reading the Error
///
/// - ``kind``
/// - ``Kind``
/// - ``errorDescription``
/// - ``failureReason``
///
/// ### Creating Errors
///
/// - ``badStatus(_:)``
/// - ``simple(_:)``
/// - ``custom(kind:message:underlyingError:)``
public struct NetSkeinError: Error, Sendable {
    /// The category of a ``NetSkeinError``.
    ///
    /// New kinds may be added in future versions, so a `switch` over it needs a `default` case.
    @nonexhaustive
    public enum Kind: Equatable, Hashable, Sendable {
        /// No response arrived: the connection failed, DNS lookup or the TLS handshake failed, an
        /// attempt timed out, or the body was cut off while arriving.
        ///
        /// The standard retry policy retries it.
        case networkFailure

        /// A body couldn't be encoded or decoded, such as a response that isn't the JSON you
        /// expected, or a response body larger than ``NetSkeinRequest/maxResponseBytes(_:)``.
        case invalidPayload

        /// The server answered with a `4xx` status, reported by ``NetSkeinResponse/validate()``.
        /// Also used when a closure you passed, such as a stream's chunk handler, throws.
        case clientError

        /// The server answered with a `5xx` status, reported by ``NetSkeinResponse/validate()``.
        case serverError

        /// The response had no body, but the call needed one, such as
        /// ``NetSkeinResponse/json(_:decoder:)``.
        case emptyResponseBody

        /// Reading or writing a local file failed, such as an upload file that doesn't exist or a
        /// download path that can't be written.
        case ioFailure

        /// A middleware threw an error that isn't a ``NetSkeinError``, such as failing to fetch a
        /// token. The middleware's error is kept as the underlying error.
        case middlewareFailure

        /// The client refused to send the request for now, such as when a ``CircuitBreaker`` is
        /// open. It's decided locally, without contacting the server, so it isn't a `403`. The
        /// same request may be sent later, and the error's message says why it was refused. Not
        /// retried by ``RetryPolicy/standard(maxRetries:backoff:retryNonIdempotent:maxRetryAfter:)``.
        case notPermitted

        /// The request was refused before it was sent, because it can't be sent as built, such
        /// as a URL without a scheme or host. Retrying won't help: the request has to change.
        /// The transport's error is kept as the underlying error.
        case invalidRequest

        /// The call did not finish within its ``NetSkeinRequest/callTimeout(_:)`` and was
        /// cancelled.
        case timedOut
    }

    private enum Representation: Sendable {
        struct CustomData: Sendable {
            let message: String
            let underlyingError: (any Error & Sendable)?
        }

        case simple(Kind)
        case custom(Kind, CustomData)
    }

    private let representation: Representation

    /// The category of the error.
    public var kind: Kind {
        switch representation {
        case let .simple(kind): return kind
        case let .custom(kind, _): return kind
        }
    }
}

extension NetSkeinError {
    /// Creates an error of `kind` with that kind's standard message.
    ///
    /// Use it in your own middleware or transport to throw an error that callers handle like
    /// NetSkein's own.
    ///
    /// - Parameter kind: The category of the error.
    /// - Returns: The error, ready to throw.
    public static func simple(_ kind: Kind) -> Self {
        NetSkeinError(representation: .simple(kind))
    }

    /// Creates an error of `kind` with your own message, and optionally the error that caused it.
    ///
    /// - Parameters:
    ///   - kind: The category of the error.
    ///   - message: A readable description, returned by `localizedDescription`.
    ///   - underlyingError: The error that caused this one, if any. Its description becomes the
    ///     error's ``failureReason``.
    /// - Returns: The error, ready to throw.
    public static func custom(
        kind: Kind,
        message: String,
        underlyingError: (any Error & Sendable)? = nil
    ) -> Self {
        let data = Representation.CustomData(message: message, underlyingError: underlyingError)
        return NetSkeinError(representation: .custom(kind, data))
    }

    /// Creates the error for a response with an unexpected status, as
    /// ``NetSkeinResponse/validate()`` throws.
    ///
    /// Its kind is ``Kind/serverError`` for statuses of `500` and above, and ``Kind/clientError``
    /// otherwise.
    ///
    /// - Parameter status: The status the server returned.
    /// - Returns: The error, ready to throw.
    public static func badStatus(_ status: HTTPResponseStatus) -> Self {
        let kind: Kind = status.code >= 500 ? .serverError : .clientError
        return .custom(
            kind: kind,
            message:
                "The server returned an unexpected status code: \(status.code) (\(status.reasonPhrase))."
        )
    }

    /// The error for a response body that couldn't be collected: too large for `maxBytes`, which
    /// a retry won't change, or cut off while arriving.
    static func bodyCollectionFailed(_ error: any Error, maxBytes: Int) -> NetSkeinError {
        if error is NIOTooManyBytesError {
            return .custom(
                kind: .invalidPayload,
                message: "The response body is larger than the limit of \(maxBytes) bytes.",
                underlyingError: error
            )
        }
        return .custom(
            kind: .networkFailure,
            message: "Failed to collect response body sequence: \(error.localizedDescription)",
            underlyingError: error
        )
    }
}

extension NetSkeinError: Equatable {
    /// Returns whether two errors have the same kind and message.
    public static func == (lhs: NetSkeinError, rhs: NetSkeinError) -> Bool {
        switch (lhs.representation, rhs.representation) {
        case let (.simple(lhsKind), .simple(rhsKind)): return lhsKind == rhsKind
        case let (.custom(lhsKind, lhsData), .custom(rhsKind, rhsData)):
            return lhsKind == rhsKind && lhsData.message == rhsData.message
        default: return false
        }
    }
}

extension NetSkeinError: Hashable {
    /// Hashes the error's kind and message, matching `==`.
    public func hash(into hasher: inout Hasher) {
        switch representation {
        case let .simple(kind):
            hasher.combine(0)
            hasher.combine(kind)
        case let .custom(kind, data):
            hasher.combine(1)
            hasher.combine(kind)
            hasher.combine(data.message)
        }
    }
}

extension NetSkeinError: LocalizedError {
    /// A readable description of what went wrong. The message for errors created with
    /// ``custom(kind:message:underlyingError:)``.
    public var errorDescription: String? {
        switch representation {
        case let .simple(kind):
            switch kind {
            case .networkFailure:
                return "A network connectivity or timeout error occurred."
            case .invalidPayload:
                return
                    "Failed to process the request or response payload data structural requirements."
            case .clientError:
                return "The request could not be fulfilled due to a client-side error."
            case .serverError:
                return "The server encountered an internal error or failed to fulfill the request."
            case .emptyResponseBody:
                return
                    "The server responded successfully, but the response body was unexpectedly empty."
            case .ioFailure:
                return "A local filesystem or storage input/output error occurred."
            case .middlewareFailure:
                return "A middleware failed while handling the request."
            case .notPermitted:
                return "The client did not permit the request to be sent for now."
            case .invalidRequest:
                return "The request was not sent because it can't be sent as built."
            case .timedOut:
                return "The call did not finish within its time limit."
            }
        case let .custom(_, data):
            return data.message
        }
    }

    /// Why it went wrong: the underlying error's description for errors created with
    /// ``custom(kind:message:underlyingError:)``, or a general explanation of the kind otherwise.
    public var failureReason: String? {
        switch representation {
        case let .simple(kind):
            switch kind {
            case .networkFailure:
                return
                    "The execution loop was cut short due to an unstable internet connection, DNS resolution failure, or SSL handshake rejection."
            case .invalidPayload:
                return
                    "The client data constraints failed locally during serialization or the received data buffer could not be properly mapped via the decoder layer."
            case .clientError:
                return
                    "The server rejected the request. Please verify the request parameters, authentication tokens, or resource permissions."
            case .serverError:
                return
                    "The upstream server is currently unavailable, misconfigured, or experiencing temporary outages. Automatic retry may be viable."
            case .emptyResponseBody:
                return "The content buffer contains zero readable bytes."
            case .ioFailure:
                return
                    "The local disk storage was unable to allocate a secure file handle read/write session, or the designated path resource is absent."
            case .middlewareFailure:
                return
                    "A registered middleware threw an error of its own, such as failing to obtain credentials, before a response could be produced."
            case .notPermitted:
                return
                    "A limit in the client, such as an open circuit breaker, is holding requests back for a while. Try again later."
            case .invalidRequest:
                return
                    "The request is malformed, such as a URL without a scheme or host, and must be changed before it can be sent."
            case .timedOut:
                return
                    "The attempts, the waits between them, and reading the response together took longer than the call's time limit."
            }
        case let .custom(_, data):
            return data.underlyingError?.localizedDescription
        }
    }
}
