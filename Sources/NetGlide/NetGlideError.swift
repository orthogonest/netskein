import NIOHTTP1

public enum NetGlideError: Error, Equatable, Hashable {
    case badStatus(HTTPResponseStatus)
    case emptyResponseBody
}
