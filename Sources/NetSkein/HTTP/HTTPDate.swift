import Foundation
import NIOHTTP1

/// Reads and writes the date formats HTTP uses in headers such as `Date`, `Expires`,
/// `Last-Modified` and `Retry-After` (RFC 9110 §5.6.7).
enum HTTPDate {
    /// `Sun, 06 Nov 1994 08:49:37 GMT`, then the obsolete `Sunday, 06-Nov-94 08:49:37 GMT`
    /// and `Sun Nov  6 08:49:37 1994`, which recipients must still accept.
    private static let formatters: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEEE, dd-MMM-yy HH:mm:ss zzz",
        "EEE MMM d HH:mm:ss yyyy",
    ]
    .map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    /// The only format a sender may generate: `Sun, 06 Nov 1994 08:49:37 GMT`.
    private static let imfFixdate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    static func parse(_ value: String) -> Date? {
        // asctime pads single-digit days with a second space
        let normalized = value.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        for formatter in formatters {
            if let date = formatter.date(from: normalized) { return date }
        }
        return nil
    }

    /// `date` in the format senders must use, such as `Sun, 06 Nov 1994 08:49:37 GMT`.
    static func string(from date: Date) -> String {
        imfFixdate.string(from: date)
    }
}

extension HTTPHeaders {
    /// Adds a `Date` set to `received` when there is none, as a recipient that stores a response
    /// must (RFC 9110 §6.6.1).
    mutating func addDateIfMissing(received: Date) {
        if !contains(name: "Date") {
            add(name: "Date", value: HTTPDate.string(from: received))
        }
    }
}
