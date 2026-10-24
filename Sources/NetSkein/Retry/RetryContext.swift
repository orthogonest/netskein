import NIOHTTP1

public struct RetryContext: Sendable {
    public let attempt: Int  // 1-based attempt counter
    public let maxRetries: Int
    public let method: HTTPMethod
    public let url: String
    public let responseStatus: HTTPResponseStatus?
    public let responseHeaders: HTTPHeaders?
    public let error: NetSkeinError?
}
