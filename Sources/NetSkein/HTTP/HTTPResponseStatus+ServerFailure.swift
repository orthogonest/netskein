import NIOHTTP1

extension HTTPResponseStatus {
    /// The statuses RFC 5861 §4 treats as the server failing, rather than answering:
    /// `500`, `502`, `503` and `504`.
    var isServerFailure: Bool {
        [500, 502, 503, 504].contains(code)
    }
}
