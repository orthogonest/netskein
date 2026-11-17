import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// A clock that only moves when a test tells it to.
///
/// Pass it to ``NetSkein/HTTPCache/testing(clock:storage:maxEntryBytes:defaultTTL:maxStaleOnError:defaultPolicy:)``
/// to test freshness and expiry without waiting:
///
/// ```swift
/// let clock = TestClock()
/// let cache = HTTPCache.testing(clock: clock)
///
/// // … send a request whose response has `Cache-Control: max-age=60` …
/// clock.advance(by: .seconds(61))
/// // … the next request finds the cached response stale …
/// ```
public final class TestClock: Sendable {
    private let current: NIOLockedValueBox<Date>

    /// Creates a clock stopped at `start`.
    ///
    /// - Parameter start: The time the clock shows until it is advanced
    ///   (default: 14 November 2023, 22:13:20 UTC). The default is fixed, so a test gives the
    ///   same result every time it runs.
    public init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = NIOLockedValueBox(start)
    }

    /// The time the clock shows.
    public var now: Date {
        current.withLockedValue { $0 }
    }

    /// Moves the clock forward by `amount`.
    ///
    /// - Parameter amount: How far to move the clock. A negative amount moves it back.
    public func advance(by amount: TimeAmount) {
        current.withLockedValue { $0 += Double(amount.nanoseconds) / 1_000_000_000 }
    }
}
