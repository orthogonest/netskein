import Foundation

/// Percent-encodes path segments and form fields.
///
/// NetSkein uses ``default`` for ``PathSegment`` interpolation and ``NetSkeinRequest/form(_:)``
/// bodies. You rarely need it directly.
public struct PercentEncoder: Sendable {
    /// The shared encoder that NetSkein uses.
    public static let `default`: Self = PercentEncoder()

    private let pathAllowedCharacters: CharacterSet
    private let formAllowedCharacters: CharacterSet

    /// Encodes with Foundation. Tests replace it to make encoding fail, which Foundation does
    /// only for strings that can't be represented, so the fallback paths can be covered.
    var _percentEncode: @Sendable (String, CharacterSet) -> String? = {
        string,
        allowedCharacters in
        string.addingPercentEncoding(withAllowedCharacters: allowedCharacters)
    }

    /// Creates an encoder.
    public init() {
        var pathChars = CharacterSet.urlPathAllowed
        pathChars.remove(charactersIn: "+/")
        self.pathAllowedCharacters = pathChars

        var characters = CharacterSet.urlQueryAllowed
        characters.remove(charactersIn: "&=+@?/$#,:; ")
        self.formAllowedCharacters = characters
    }

    /// Returns `segment` encoded for use as one path segment, so `/` becomes `%2F` and `+` becomes
    /// `%2B`.
    ///
    /// - Parameter segment: The text to encode, such as a user name.
    /// - Returns: The encoded segment.
    public func encodePath(_ segment: String) -> String {
        _percentEncode(segment, pathAllowedCharacters) ?? segment
    }

    /// Returns `fields` encoded as an `application/x-www-form-urlencoded` body, such as
    /// `name=Ada+Lovelace&role=admin`.
    ///
    /// Spaces become `+`, and characters with a meaning in forms, such as `&`, `=` and `+`, are
    /// percent-encoded. Fields are sorted, so the same fields always produce the same body.
    ///
    /// - Parameter fields: The form fields, by name.
    /// - Returns: The encoded body, ready to send.
    public func encodeForm(_ fields: [String: String]) -> String {
        let encodedPairs = fields.map { (key, value) -> String in
            let escapedKey = _percentEncode(key, formAllowedCharacters) ?? key
            let escapedValue = _percentEncode(value, formAllowedCharacters) ?? value
            let cleanedKey = escapedKey.replacingOccurrences(of: "%20", with: "+")
            let cleanedValue = escapedValue.replacingOccurrences(of: "%20", with: "+")
            return "\(cleanedKey)=\(cleanedValue)"
        }
        return encodedPairs.sorted().joined(separator: "&")
    }
}
