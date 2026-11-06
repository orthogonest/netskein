import Foundation
import NIOCore
import NIOHTTP1

enum RetryAfterParser {
    static func parseDelay(from headers: HTTPHeaders?) -> TimeAmount? {
        guard let retryAfter = headers?.first(name: "Retry-After") else { return nil }

        if let seconds = Int64(retryAfter), seconds >= 0 {
            return .seconds(seconds)
        }

        if let date = HTTPDate.parse(retryAfter) {
            let nanoseconds = date.timeIntervalSinceNow * 1_000_000_000
            guard nanoseconds > 0 else { return .nanoseconds(0) }
            return .nanoseconds(nanoseconds < Double(Int64.max) ? Int64(nanoseconds) : .max)
        }

        return nil
    }
}
