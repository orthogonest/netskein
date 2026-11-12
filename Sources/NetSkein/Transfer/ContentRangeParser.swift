import Foundation

enum ContentRangeParser {
    /// The full length from a `Content-Range` value, such as `67589` from
    /// `bytes 200-1000/67589`. `nil` when the length is `*` or the value is malformed.
    static func parseTotalBytes(from header: String?) -> Int64? {
        guard let header else { return nil }
        guard let slashIndex = header.lastIndex(of: "/") else { return nil }
        let totalSubstring = header[header.index(after: slashIndex)...]
            .trimmingCharacters(in: .whitespaces)
        return Int64(totalSubstring)
    }
}
