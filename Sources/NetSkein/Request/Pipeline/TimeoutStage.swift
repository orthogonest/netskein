import Foundation
import NIOCore

/// Limits the whole call, every attempt and wait included. A `nil` limit sets none.
///
/// Runs the call next to a timer. When the timer ends first, the call is cancelled, which stops
/// the request in flight, any body being read and any wait for a retry, and the call fails with
/// ``NetSkeinError/Kind/timedOut``.
struct TimeoutStage: Sendable {
    let limit: TimeAmount?

    func run<Success: Sendable>(
        _ call: @escaping @Sendable () async throws(NetSkeinError) -> Success
    ) async throws(NetSkeinError) -> Success {
        guard let limit else { return try await call() }

        let finished = await withTaskGroup(of: Result<Success, NetSkeinError>?.self) { group in
            group.addTask {
                await Result { () async throws(NetSkeinError) in try await call() }
            }
            group.addTask {
                // Ends with nil when the limit passes, or when the caller cancels
                try? await Task.sleep(nanoseconds: UInt64(max(0, limit.nanoseconds)))
                return nil
            }

            let first = await group.next().flatMap { $0 }
            group.cancelAll()
            return first
        }

        if let finished { return try finished.get() }

        // The timer also ends early when the caller cancels. Report that as a cancellation
        try checkCancellation()
        let seconds = Double(limit.nanoseconds) / Nanoseconds.toSeconds
        throw .custom(
            kind: .timedOut,
            message: "The call did not finish within \(String(format: "%g", seconds)) s."
        )
    }
}
