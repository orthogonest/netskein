import NIOHTTP1

extension HTTPMethod {
    var isIdempotent: Bool {
        switch self {
        case .GET, .HEAD, .PUT, .DELETE, .OPTIONS, .TRACE:
            return true
        default:
            return false
        }
    }
}
