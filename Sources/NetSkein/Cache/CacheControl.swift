import Foundation
import NIOHTTP1

/// The directives of every `Cache-Control` field in a request or response (RFC 9111 §5.2).
///
/// Directive names are case-insensitive. When a directive appears more than once, the first
/// occurrence wins.
struct CacheControl {
    /// The largest delta-seconds value a cache must handle (RFC 9111 §1.2.2).
    static let maxDeltaSeconds = 2_147_483_648

    private var directives: [String: String?] = [:]

    init(_ headers: HTTPHeaders) {
        for field in headers["Cache-Control"] {
            for directive in Self.split(field) {
                let name: Substring
                let value: String?
                if let equals = directive.firstIndex(of: "=") {
                    name = directive[..<equals]
                    value = Self.unquoted(directive[directive.index(after: equals)...])
                } else {
                    name = directive
                    value = nil
                }

                let key = name.trimmingCharacters(in: .whitespaces).lowercased()
                guard !key.isEmpty, directives[key] == nil else { continue }
                directives[key] = .some(value)
            }
        }
    }
}

extension CacheControl {
    func contains(_ name: String) -> Bool {
        directives[name] != nil
    }

    /// Whether the directive is present with an argument, such as `max-stale=60` rather than
    /// `max-stale`.
    func hasArgument(_ name: String) -> Bool {
        (directives[name] ?? nil) != nil
    }

    /// The directive's delta-seconds value: `nil` when absent, `0` when the value is missing or
    /// invalid, so a malformed directive errs on the side of not reusing a response.
    func seconds(_ name: String) -> Int? {
        guard let value = directives[name] else { return nil }
        guard let value, !value.isEmpty, value.allSatisfy({ "0"..."9" ~= $0 }) else { return 0 }
        return Int(value).map { min($0, Self.maxDeltaSeconds) } ?? Self.maxDeltaSeconds
    }
}

extension CacheControl {
    /// Splits a field on the commas outside quoted strings.
    private static func split(_ field: String) -> [Substring] {
        var parts: [Substring] = []
        var start = field.startIndex
        var isQuoted = false
        for index in field.indices {
            switch field[index] {
            case "\"": isQuoted.toggle()
            case "," where !isQuoted:
                parts.append(field[start..<index])
                start = field.index(after: index)
            default: break
            }
        }
        parts.append(field[start...])
        return parts
    }

    private static func unquoted(_ value: Substring) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
    }
}
