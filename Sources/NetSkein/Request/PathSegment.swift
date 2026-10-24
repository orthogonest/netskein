import Foundation

public struct PathSegment: ExpressibleByStringInterpolation, Sendable {
    public let value: String

    public init(stringLiteral value: String) {
        self.value = value
    }

    public init(stringInterpolation: StringInterpolation) {
        self.value = stringInterpolation.output
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var output: String = ""

        public init(literalCapacity: Int, interpolationCount: Int) {
            output.reserveCapacity(literalCapacity + interpolationCount * 5)
        }

        public mutating func appendLiteral(_ literal: StringLiteralType) {
            output.append(literal)
        }

        public mutating func appendInterpolation(_ param: String) {
            let encoded = PercentEncoder.default.encodePath(param)
            output.append(encoded)
        }

        public mutating func appendInterpolation(_ param: Int) {
            output.append(String(param))
        }

        public mutating func appendInterpolation(_ param: UUID) {
            output.append(param.uuidString)
        }
    }
}
