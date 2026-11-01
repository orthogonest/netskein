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
    ///   It must be strong: a weak `ETag` such as `W/"v1"` is ignored, because `If-Range` only
    ///   accepts validators that guarantee identical bytes.
    case ifPossible(validator: String? = nil)
}

extension DownloadResumption {
    /// The caller's validator, to send as `If-Range`: `nil` when there is none, and for a weak
    /// `ETag`, which `If-Range` does not allow (RFC 9110 §13.1.5).
    var ifRangeValidator: String? {
        guard case let .ifPossible(validator?) = self, !HTTPValidator.isWeak(validator) else {
            return nil
        }
        return validator
    }
}
