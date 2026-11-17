/// Whether ``NetSkeinRequest/download(toFileAtPath:resumption:onProgress:)`` continues a
/// partial file instead of downloading it again from the start.
///
/// Resuming sends a `Range` header asking for the bytes after those on disk. It sends
/// `If-Range` too when a strong validator is known, so that a server whose file has changed
/// sends the whole new file instead of the rest of a different one. Only `GET` requests resume.
public enum DownloadResumption: Equatable, Sendable {
    /// Never resumes: the file is replaced at the start of the download, and every retry writes
    /// it again from the start. A download that fails deletes the file.
    case disabled

    /// Resumes on retries: a file already at the path is replaced, and when an attempt fails,
    /// the next one continues from what it wrote. A download that fails once the retries are
    /// used up deletes the file.
    ///
    /// Retries send `If-Range` with the `ETag` or `Last-Modified` of the earlier response, when
    /// it had a strong one.
    case onRetry

    /// Resumes a file already at the path, as well as on retries. A download that fails keeps
    /// what it wrote, so a later download can resume it.
    ///
    /// - Warning: Without a validator, the first attempt sends `Range` without `If-Range`, and
    ///   logs a warning. If the file on the server has changed since the partial file was
    ///   written, the result mixes the two versions. Pass the `ETag` or `Last-Modified` you
    ///   saved with the file, or `nil` only when the file never changes, such as at a versioned
    ///   URL.
    ///
    /// - Parameter validator: The `ETag` or `Last-Modified` of the partial file, sent as
    ///   `If-Range`, or `nil` for none. It must be strong: a weak `ETag` such as `W/"v1"` is
    ///   ignored, because `If-Range` only accepts validators that guarantee identical bytes.
    case ifPossible(validator: String?)
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
