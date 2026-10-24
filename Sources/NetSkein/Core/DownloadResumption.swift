/// Strategy for handling partial download resumption.
public enum DownloadResumption: Equatable, Sendable {
    /// Overwrites existing files and restarts from byte 0 on retries.
    /// Safest default for general-purpose HTTP requests.
    case disabled

    /// If a network failure occurs during retries, automatically resumes from the
    /// bytes already written using `Range` and `If-Range` (via captured `ETag`/`Last-Modified`).
    /// Pre-existing files at the destination path before attempt 0 are overwritten.
    case onRetry

    /// Attempts to resume an existing file already at the destination path (if present),
    /// as well as handling retry resumption.
    /// - Parameter validator: Optional known `ETag` or `Last-Modified` date to validate against.
    case ifPossible(validator: String? = nil)
}

extension DownloadResumption {
    var validator: String? {
        switch self {
        case let .ifPossible(validator): return validator
        case .disabled, .onRetry: return nil
        }
    }
}
