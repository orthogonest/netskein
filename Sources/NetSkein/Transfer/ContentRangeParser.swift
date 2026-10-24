enum ContentRangeParser {
    /// Parses the complete resource length from a `Content-Range` header value (e.g., "bytes 200-1000/67589").
    static func parseTotalBytes(from header: String?) -> Int64? {
        guard let header else { return nil }
        guard let slashIndex = header.lastIndex(of: "/") else { return nil }
        let totalSubstring = header[header.index(after: slashIndex)...]
            .trimmingCharacters(in: .whitespaces)
        return Int64(totalSubstring)
    }
}
