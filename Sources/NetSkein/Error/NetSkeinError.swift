import Foundation
import NIOHTTP1

public struct NetSkeinError: Error, Sendable {
    @nonexhaustive
    public enum Kind: Equatable, Hashable, Sendable {
        case networkFailure
        case invalidPayload
        case clientError
        case serverError
        case emptyResponseBody
        case ioFailure
        case middlewareFailure
        /// A ``CircuitBreaker`` rejected the request without sending it, because the server kept
        /// failing. Not retried by ``RetryPolicy/standard(maxRetries:backoff:retryNonIdempotent:maxRetryAfter:)``.
        case circuitOpen
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

    public var kind: Kind {
        switch representation {
        case let .simple(kind): return kind
        case let .custom(kind, _): return kind
        }
    }
}

extension NetSkeinError {
    public static func simple(_ kind: Kind) -> Self {
        NetSkeinError(representation: .simple(kind))
    }

    public static func custom(
        kind: Kind,
        message: String,
        underlyingError: (any Error & Sendable)? = nil
    ) -> Self {
        let data = Representation.CustomData(message: message, underlyingError: underlyingError)
        return NetSkeinError(representation: .custom(kind, data))
    }

    public static func badStatus(_ status: HTTPResponseStatus) -> Self {
        let kind: Kind = status.code >= 500 ? .serverError : .clientError
        return .custom(
            kind: kind,
            message:
                "The server returned an unexpected status code: \(status.code) (\(status.reasonPhrase))."
        )
    }
}

extension NetSkeinError: Equatable {
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
            case .circuitOpen:
                return "The request was not sent because the server's circuit breaker is open."
            case .timedOut:
                return "The call did not finish within its time limit."
            }
        case let .custom(_, data):
            return data.message
        }
    }

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
            case .circuitOpen:
                return
                    "The server failed repeatedly, so requests to it are rejected for a while to let it recover."
            case .timedOut:
                return
                    "The attempts, the waits between them, and reading the response together took longer than the call's time limit."
            }
        case let .custom(_, data):
            return data.underlyingError?.localizedDescription
        }
    }
}
