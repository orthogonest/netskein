import Foundation

/// A production-grade encoder specifically engineered to satisfy the strict W3C 'application/x-www-form-urlencoded' specifications.
public struct NetSkeinURLEncoder: Sendable {
    private let formAllowedCharacters: CharacterSet

    internal var _percentEncode: @Sendable (String, CharacterSet) -> String? = {
        string,
        allowedCharacters in
        string.addingPercentEncoding(withAllowedCharacters: allowedCharacters)
    }

    public init() {
        var characters = CharacterSet.urlQueryAllowed
        // Remove characters that are legal in a standard URL query but illegal or volatile inside a Form Body
        characters.remove(charactersIn: "&=+@?/$#,:; ")
        self.formAllowedCharacters = characters
    }

    /// Encodes a dictionary of scalar fields into a compliant urlencoded string block.
    public func encode(_ fields: [String: String]) -> String {
        let encodedPairs = fields.map { (key, value) -> String in
            let escapedKey = _percentEncode(key, formAllowedCharacters) ?? key

            // Standardize spaces to "+" as strictly recommended by the W3C form specifications layout
            let escapedValue = _percentEncode(value, formAllowedCharacters) ?? value
            let cleanValue = escapedValue.replacingOccurrences(of: "%20", with: "+")

            return "\(escapedKey)=\(cleanValue)"
        }

        // Join properties utilizing the structural ampersand token
        return encodedPairs.sorted().joined(separator: "&")
    }
}
