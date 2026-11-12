import Foundation
import NIOHTTP1

/// The validators of one response: the `ETag` and `Last-Modified` that identify the version of
/// the resource it carries (RFC 9110 §8.8).
///
/// A later request sends them back to ask whether that version is still current: the HTTP cache
/// with `If-None-Match` and `If-Modified-Since`, a resumed download with `If-Range`.
struct HTTPValidator {
    /// The `ETag` exactly as the server sent it, such as `"v7"` or the weak `W/"v7"`.
    let entityTag: String?

    /// The `Last-Modified` date exactly as the server sent it.
    let lastModified: String?

    /// The response's `Date`, which decides whether `lastModified` is strong.
    private let date: Date?

    init(_ headers: HTTPHeaders) {
        entityTag = headers.first(name: "ETag")
        lastModified = headers.first(name: "Last-Modified")
        date = headers.first(name: "Date").flatMap(HTTPDate.parse)
    }
}

extension HTTPValidator {
    /// The headers asking whether this version is still current. The server answers
    /// `304 Not Modified` when it is (RFC 9110 §13.1.2, §13.1.3).
    var conditionalHeaders: HTTPHeaders {
        var headers = HTTPHeaders()
        if let entityTag { headers.add(name: "If-None-Match", value: entityTag) }
        if let lastModified { headers.add(name: "If-Modified-Since", value: lastModified) }
        return headers
    }

    /// The value for `If-Range`, which must be a strong validator: appending bytes needs the
    /// exact same bytes, not just equivalent content (RFC 9110 §13.1.5).
    ///
    /// A weak `ETag` is never used. A `Last-Modified` is only strong when it is at least one
    /// second older than the response's `Date`, because a resource can change twice within the
    /// same second (RFC 9110 §8.8.2.2).
    var ifRange: String? {
        if let entityTag, !Self.isWeak(entityTag) { return entityTag }
        guard
            let lastModified,
            let modified = HTTPDate.parse(lastModified),
            let date,
            date.timeIntervalSince(modified) >= 1
        else { return nil }
        return lastModified
    }

    /// Whether `other`, such as the validators of a `304 Not Modified`, refers to the same version.
    ///
    /// Entity tags use the weak comparison, which ignores the `W/` prefix (RFC 9110 §8.8.3.2).
    /// Without one, `Last-Modified` must be equal. Without either, nothing contradicts a match
    /// (RFC 9111 §4.3.4).
    func matches(_ other: HTTPValidator) -> Bool {
        if let otherTag = other.entityTag {
            return entityTag.map(Self.opaqueTag) == Self.opaqueTag(otherTag)
        }
        if let otherDate = other.lastModified {
            return lastModified == otherDate
        }
        return true
    }

    static func isWeak(_ entityTag: String) -> Bool {
        entityTag.hasPrefix("W/")
    }

    private static func opaqueTag(_ entityTag: String) -> Substring {
        isWeak(entityTag) ? entityTag.dropFirst(2) : Substring(entityTag)
    }
}
