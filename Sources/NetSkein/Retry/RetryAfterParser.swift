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
            let diff = date.timeIntervalSinceNow
            return diff > 0 ? .nanoseconds(Int64(diff * 1_000_000_000)) : .nanoseconds(0)
        }

        return nil
    }
}
