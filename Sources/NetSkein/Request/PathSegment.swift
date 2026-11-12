import Foundation

/// A piece of a URL path that encodes the values you interpolate into it.
///
/// You write a path segment as a string literal in ``NetSkeinRequest/path(_:)``:
///
/// ```swift
/// client.get("https://api.example.com")
///     .path("users/\(username)/posts/\(postID)")
/// ```
///
/// The literal text, including its `/`, is used as written. Interpolated `String` values are
/// percent-encoded, including `/`, `?`, `#` and `+`, so a value such as `"../admin"` stays a single
/// segment. `Int` and `UUID` values are inserted as they are, since they can't contain those
/// characters.
///
/// To interpolate another type, convert it to a `String` first.
public struct PathSegment: ExpressibleByStringInterpolation, Sendable {
    /// The finished path text, with interpolated values encoded.
    public let value: String

    /// Creates a segment from a literal without interpolation, used as written.
    public init(stringLiteral value: String) {
        self.value = value
    }

    /// Creates a segment from a literal with interpolated values.
    public init(stringInterpolation: StringInterpolation) {
        self.value = stringInterpolation.output
    }

    /// Builds a ``PathSegment`` from a string literal, encoding each interpolated value.
    ///
    /// The compiler uses this type when you write a literal with interpolation. You don't call it
    /// yourself.
    public struct StringInterpolation: StringInterpolationProtocol {
        var output: String = ""

        /// Creates an empty interpolation, reserving space for the result.
        public init(literalCapacity: Int, interpolationCount: Int) {
            output.reserveCapacity(literalCapacity + interpolationCount * 5)
        }

        /// Appends literal text as written.
        public mutating func appendLiteral(_ literal: StringLiteralType) {
            output.append(literal)
        }

        /// Appends `param` percent-encoded, so it can't add path components, a query or a fragment.
        ///
        /// - Parameter param: The value to insert, such as a user name.
        public mutating func appendInterpolation(_ param: String) {
            let encoded = PercentEncoder.default.encodePath(param)
            output.append(encoded)
        }

        /// Appends `param` in decimal.
        ///
        /// - Parameter param: The number to insert, such as an ID.
        public mutating func appendInterpolation(_ param: Int) {
            output.append(String(param))
        }

        /// Appends `param` in its standard uppercase form.
        ///
        /// - Parameter param: The identifier to insert.
        public mutating func appendInterpolation(_ param: UUID) {
            output.append(param.uuidString)
        }
    }
}
