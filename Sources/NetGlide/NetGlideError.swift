import Foundation
import NIOHTTP1

public enum NetGlideError: Error, Equatable, Hashable {
    case badStatus(HTTPResponseStatus)
    case emptyResponseBody
    case fileNotFound(String)
}

extension NetGlideError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .badStatus(status):
            return "The server returned an unexpected status code: \(status.code) (\(status.reasonPhrase))."
        case .emptyResponseBody:
            return "The server responded successfully, but the response body was unexpectedly empty."
        case let .fileNotFound(path):
            return "Unable to initiate data stream. File not found at the specified path: \(path)."
        }
    }

    public var failureReason: String? {
        switch self {
        case .badStatus:
            return "The request completed, but the server's business logic requirements or authentication constraints failed."
        case .emptyResponseBody:
            return "The content buffer contains zero readable bytes."
        case .fileNotFound:
            return "The filesystem layer was unable to allocate a secure file handle read session."
        }
    }
}
