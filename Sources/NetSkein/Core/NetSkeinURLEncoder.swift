import Foundation

public struct NetSkeinURLEncoder: Sendable {
    public static let `default`: Self = NetSkeinURLEncoder()

    private let pathAllowedCharacters: CharacterSet
    private let formAllowedCharacters: CharacterSet

    var _percentEncode: @Sendable (String, CharacterSet) -> String? = {
        string,
        allowedCharacters in
        string.addingPercentEncoding(withAllowedCharacters: allowedCharacters)
    }

    public init() {
        var pathChars = CharacterSet.urlPathAllowed
        pathChars.remove(charactersIn: "+/")
        self.pathAllowedCharacters = pathChars

        var characters = CharacterSet.urlQueryAllowed
        characters.remove(charactersIn: "&=+@?/$#,:; ")
        self.formAllowedCharacters = characters
    }

    public func encodePath(_ segment: String) -> String {
        _percentEncode(segment, pathAllowedCharacters) ?? segment
    }

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
