import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1

/// Stops sending requests to a server that keeps failing, so the server can recover and callers
/// fail fast instead of waiting on it.
///
/// Create one, keep a reference, and pass it to the client builder's `circuitBreaker(_:)`. The
/// breaker is safe to share between clients that call the same servers.
///
/// ```swift
/// let breaker = CircuitBreaker(failureThreshold: 5, openDuration: .seconds(30))
/// let client = NetSkeinClient.builder().circuitBreaker(breaker).build()
/// ```
///
/// Each server, by default each origin (scheme, host, and port), has its own circuit:
///
/// - **Closed**: requests are sent. After `failureThreshold` failures in a row, the circuit
///   opens.
/// - **Open**: requests fail at once with ``NetSkeinError/Kind/circuitOpen``, without being
///   sent, until `openDuration` has passed.
/// - **Half-open**: up to `halfOpenMaxRequests` trial requests are sent. A success closes the
///   circuit; a failure opens it again for another `openDuration`.
///
/// The breaker counts every attempt, including retries, and judges each one by its response
/// status or error, before the body is read. A cancelled request is not counted. The standard
/// retry policy does not retry `circuitOpen`, so a call to an open circuit ends right away.
///
/// The client places the breaker between the cache and the network. Fresh cached responses are
/// still served while a circuit is open, and with ``HTTPCache``'s `maxStaleOnError` a stale one
/// can stand in for the rejected request.
public final class CircuitBreaker: Sendable {
    /// Names the circuit a request belongs to.
    public typealias Key = @Sendable (RequestHead) -> String

    /// Whether an attempt's response status, or the error it failed with, counts as a failure.
    public typealias FailureEvaluator =
        @Sendable (Result<HTTPResponseStatus, NetSkeinError>) -> Bool

    /// The state of one circuit.
    public enum State: Sendable, Equatable {
        /// Requests are sent.
        case closed
        /// Requests are rejected until `until`; the first request after it is a trial.
        case open(until: Date)
        /// Trial requests are being sent to find out whether the server has recovered.
        case halfOpen
    }

    let failureThreshold: Int
    let openDuration: TimeAmount
    let halfOpenMaxRequests: Int
    let key: Key
    let isFailure: FailureEvaluator
    let now: @Sendable () -> Date
    /// The circuits that are not closed with zero failures; a missing key is a healthy circuit.
    private let circuits: NIOLockedValueBox<[String: Circuit]>

    /// - Parameters:
    ///   - failureThreshold: Failures in a row that open a circuit. At least 1.
    ///   - openDuration: How long an open circuit rejects requests before allowing a trial.
    ///   - halfOpenMaxRequests: Trial requests allowed at the same time while half-open. At
    ///     least 1.
    ///   - key: Names the circuit a request belongs to; ``origin(of:)`` by default, so each
    ///     server has its own.
    ///   - isFailure: Whether an attempt counts as a failure; ``isServerFailure(_:)`` by
    ///     default: network failures and `500`, `502`, `503` and `504`. Other statuses, such as
    ///     `404` or `429`, mean the server is answering.
    public convenience init(
        failureThreshold: Int = 5,
        openDuration: TimeAmount = .seconds(30),
        halfOpenMaxRequests: Int = 1,
        key: @escaping Key = CircuitBreaker.origin(of:),
        isFailure: @escaping FailureEvaluator = CircuitBreaker.isServerFailure(_:)
    ) {
        self.init(
            failureThreshold: failureThreshold,
            openDuration: openDuration,
            halfOpenMaxRequests: halfOpenMaxRequests,
            key: key,
            isFailure: isFailure,
            now: { Date() }
        )
    }

    /// The full initializer, with the clock injected; `NetSkeinTesting` uses it for
    /// `CircuitBreaker.testing(…)`.
    package init(
        failureThreshold: Int,
        openDuration: TimeAmount,
        halfOpenMaxRequests: Int,
        key: @escaping Key,
        isFailure: @escaping FailureEvaluator,
        now: @escaping @Sendable () -> Date
    ) {
        self.failureThreshold = max(1, failureThreshold)
        self.openDuration = openDuration
        self.halfOpenMaxRequests = max(1, halfOpenMaxRequests)
        self.key = key
        self.isFailure = isFailure
        self.now = now
        self.circuits = NIOLockedValueBox([:])
    }
}

// MARK: - Defaults

extension CircuitBreaker {
    /// The request's origin, its scheme, host and port, such as `https://api.example.com:8443`.
    /// A URL without a host is used as it is.
    public static func origin(of request: RequestHead) -> String {
        guard
            let components = URLComponents(string: request.url),
            let host = components.host
        else { return request.url }

        let scheme = components.scheme ?? ""

        var origin = "\(scheme.lowercased())://\(host.lowercased())"
        if let port = components.port {
            origin += ":\(port)"
        }

        return origin
    }

    /// Whether the server failed: a network failure, or `500`, `502`, `503` or `504`.
    public static func isServerFailure(
        _ outcome: Result<HTTPResponseStatus, NetSkeinError>
    ) -> Bool {
        switch outcome {
        case let .success(status): status.isServerFailure
        case let .failure(error): error.kind == .networkFailure
        }
    }
}

// MARK: - State

extension CircuitBreaker {
    /// The state of the circuit named `key`, such as an ``origin(of:)``.
    ///
    /// An open circuit whose `until` has passed reports `open` until a request arrives and
    /// makes it half-open.
    public func state(for key: String) -> State {
        switch circuits.withLockedValue({ $0[key] }) {
        case nil, .closed: .closed
        case let .open(until): .open(until: until)
        case .halfOpen: .halfOpen
        }
    }

    /// Closes every circuit and forgets every failure.
    public func reset() {
        circuits.withLockedValue { $0.removeAll() }
    }
}

// MARK: - Requests

extension CircuitBreaker {
    /// Permission to send one request, to be settled with ``record(_:for:logger:)`` or
    /// ``release(_:)``.
    struct Permit {
        let key: String
        /// Whether the request is a trial of a half-open circuit.
        let isTrial: Bool
    }

    /// One circuit, as stored; closed with zero failures is stored as no entry.
    private enum Circuit {
        case closed(failures: Int)
        case open(until: Date)
        case halfOpen(trials: Int)
    }

    /// Lets a request to the circuit `key` through, or rejects it with `circuitOpen`.
    func acquire(_ key: String, logger: Logger) throws(NetSkeinError) -> Permit {
        let now = now()
        let decision: Result<Permit, NetSkeinError> = circuits.withLockedValue { circuits in
            switch circuits[key] {
            case nil, .closed:
                return .success(Permit(key: key, isTrial: false))

            case let .open(until) where now >= until:
                circuits[key] = .halfOpen(trials: 1)
                return .success(Permit(key: key, isTrial: true))

            case let .open(until):
                let seconds = Int(until.timeIntervalSince(now).rounded(.up))
                return .failure(
                    .custom(
                        kind: .circuitOpen,
                        message:
                            "The circuit for \(key) is open after repeated failures. Requests are rejected for another \(seconds) s."
                    )
                )

            case let .halfOpen(trials) where trials < halfOpenMaxRequests:
                circuits[key] = .halfOpen(trials: trials + 1)
                return .success(Permit(key: key, isTrial: true))

            case .halfOpen:
                return .failure(
                    .custom(
                        kind: .circuitOpen,
                        message:
                            "The circuit for \(key) is half-open and its trial requests are still in flight."
                    )
                )
            }
        }

        let permit = try decision.get()
        if permit.isTrial {
            logger.info(
                "Circuit half-open. Sending a trial request",
                metadata: ["circuit": .string(key)]
            )
        }
        return permit
    }

    /// Counts the outcome of a request let through by `permit`, opening or closing its circuit
    /// when that changes its state.
    func record(
        _ outcome: Result<HTTPResponseStatus, NetSkeinError>,
        for permit: Permit,
        logger: Logger
    ) {
        let failed = isFailure(outcome)
        let now = now()
        let until = now.addingTimeInterval(Double(openDuration.nanoseconds) / Nanoseconds.toSeconds)

        let change: Change? = circuits.withLockedValue { circuits in
            switch circuits[permit.key] {
            case nil:
                return countFailure(failed, after: 0, key: permit.key, until: until, in: &circuits)
            case let .closed(failures):
                return countFailure(
                    failed,
                    after: failures,
                    key: permit.key,
                    until: until,
                    in: &circuits
                )
            case .halfOpen where permit.isTrial:
                circuits[permit.key] = failed ? .open(until: until) : nil
                return failed ? .reopened : .closed
            case .halfOpen, .open:
                // Settled by a trial, or by other requests, while this one was in flight
                return nil
            }
        }

        let metadata: Logger.Metadata = ["circuit": .string(permit.key)]
        switch change {
        case nil:
            break
        case .opened:
            logger.warning(
                "Circuit opened after \(failureThreshold) failures in a row. Rejecting requests",
                metadata: metadata
            )
        case .reopened:
            logger.warning("Circuit reopened after its trial request failed", metadata: metadata)
        case .closed:
            logger.info("Circuit closed after a successful trial request", metadata: metadata)
        }
    }

    /// Gives back a permit whose request was cancelled, so it counts neither way.
    func release(_ permit: Permit) {
        circuits.withLockedValue { circuits in
            guard permit.isTrial, case let .halfOpen(trials) = circuits[permit.key] else { return }
            circuits[permit.key] = .halfOpen(trials: trials - 1)
        }
    }

    private enum Change {
        case opened
        case reopened
        case closed
    }

    /// Counts a request to a closed circuit that had `failures` failures in a row.
    private func countFailure(
        _ failed: Bool,
        after failures: Int,
        key: String,
        until: Date,
        in circuits: inout [String: Circuit]
    ) -> Change? {
        guard failed else {
            circuits[key] = nil
            return nil
        }
        guard failures + 1 >= failureThreshold else {
            circuits[key] = .closed(failures: failures + 1)
            return nil
        }
        circuits[key] = .open(until: until)
        return .opened
    }
}
