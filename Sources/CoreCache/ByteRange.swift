import Foundation

public enum HTTPRangeParseError: Error, Equatable, Sendable {
    case emptyHeader
    case invalidUnit
    case emptyRange
    case multipleRangesNotSupported
    case missingDash
    case invalidStart
    case invalidEnd
    case invalidSuffix
    case missingTotalLength
    case overflow
    case rangeNotSatisfiable
}

/// Internal byte-range model used by cache and proxy layers.
///
/// - Important: Ranges are half-open (`[start, endExclusive)`) for safer arithmetic and easy length math.
/// HTTP Range headers are inclusive (`bytes=start-end`), so conversion always maps inclusive HTTP end to `end + 1` internally.
public struct ByteRange: Codable, Hashable, Sendable {
    public let start: Int64
    public let endExclusive: Int64

    public init?(start: Int64, endExclusive: Int64) {
        guard start >= 0, endExclusive >= start else {
            return nil
        }
        self.start = start
        self.endExclusive = endExclusive
    }

    public var length: Int64 {
        endExclusive - start
    }

    /// Converts the internal half-open range into an HTTP `Range` header value (`bytes=start-endInclusive`).
    ///
    /// If `totalLength` is provided, `endExclusive` is clamped to `totalLength` before converting.
    /// Returns an empty end (`bytes=start-`) when the resulting range has zero length.
    public func toHTTPHeaderValue(totalLength: Int64?) -> String {
        let clampedEndExclusive: Int64
        if let totalLength {
            clampedEndExclusive = max(start, min(endExclusive, totalLength))
        } else {
            clampedEndExclusive = endExclusive
        }

        if clampedEndExclusive <= start {
            return "bytes=\(start)-"
        }

        return "bytes=\(start)-\(clampedEndExclusive - 1)"
    }

    /// Parses a single HTTP `Range` value and returns a half-open internal range.
    ///
    /// Supported forms:
    /// - `bytes=START-END`
    /// - `bytes=START-`
    /// - `bytes=-SUFFIX`
    ///
    /// If `totalLength` is provided, open and suffix ranges are resolved against it and end values are clamped.
    /// Returns `nil` for invalid/multiple/empty ranges.
    public static func parseHTTPRange(_ headerValue: String, totalLength: Int64?) -> ByteRange? {
        try? parseHTTPRangeValidated(headerValue, totalLength: totalLength)
    }

    /// Strict HTTP range parser with deterministic typed errors.
    ///
    /// This variant mirrors `parseHTTPRange(_:totalLength:)` semantics for valid values but provides explicit
    /// failure reasons and overflow-safe `endInclusive + 1` conversion.
    public static func parseHTTPRangeValidated(_ headerValue: String, totalLength: Int64?) throws -> ByteRange {
        let trimmed = headerValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HTTPRangeParseError.emptyHeader
        }

        let lower = trimmed.lowercased()
        guard lower.hasPrefix("bytes=") else {
            throw HTTPRangeParseError.invalidUnit
        }

        let rawSpec = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        guard !rawSpec.isEmpty else {
            throw HTTPRangeParseError.emptyRange
        }
        guard !rawSpec.contains(",") else {
            throw HTTPRangeParseError.multipleRangesNotSupported
        }

        guard let dashIndex = rawSpec.firstIndex(of: "-") else {
            throw HTTPRangeParseError.missingDash
        }

        let startPart = String(rawSpec[..<dashIndex]).trimmingCharacters(in: .whitespaces)
        let endPart = String(rawSpec[rawSpec.index(after: dashIndex)...]).trimmingCharacters(in: .whitespaces)

        if startPart.isEmpty {
            return try parseSuffixRangeValidated(endPart, totalLength: totalLength)
        }

        guard let start = parseNonNegativeInt(startPart) else {
            throw HTTPRangeParseError.invalidStart
        }

        if endPart.isEmpty {
            guard let totalLength else {
                throw HTTPRangeParseError.missingTotalLength
            }

            let endExclusive = max(start, totalLength)
            guard endExclusive > start else {
                throw HTTPRangeParseError.rangeNotSatisfiable
            }
            guard let range = ByteRange(start: start, endExclusive: endExclusive) else {
                throw HTTPRangeParseError.rangeNotSatisfiable
            }
            return range
        }

        guard let endInclusive = parseNonNegativeInt(endPart), endInclusive >= start else {
            throw HTTPRangeParseError.invalidEnd
        }

        let (convertedEndExclusive, overflowed) = endInclusive.addingReportingOverflow(1)
        guard !overflowed else {
            throw HTTPRangeParseError.overflow
        }

        var endExclusive = convertedEndExclusive
        if let totalLength {
            endExclusive = min(endExclusive, totalLength)
        }

        guard endExclusive > start else {
            throw HTTPRangeParseError.rangeNotSatisfiable
        }

        guard let range = ByteRange(start: start, endExclusive: endExclusive) else {
            throw HTTPRangeParseError.rangeNotSatisfiable
        }
        return range
    }

    private static func parseSuffixRangeValidated(_ suffixPart: String, totalLength: Int64?) throws -> ByteRange {
        guard let totalLength else {
            throw HTTPRangeParseError.missingTotalLength
        }

        guard let suffixLength = parseNonNegativeInt(suffixPart), suffixLength > 0 else {
            throw HTTPRangeParseError.invalidSuffix
        }

        let start = max(0, totalLength - suffixLength)
        let endExclusive = max(0, totalLength)

        guard endExclusive > start else {
            throw HTTPRangeParseError.rangeNotSatisfiable
        }

        guard let range = ByteRange(start: start, endExclusive: endExclusive) else {
            throw HTTPRangeParseError.rangeNotSatisfiable
        }
        return range
    }

    private static func parseNonNegativeInt(_ value: String) -> Int64? {
        guard !value.isEmpty, value.first != "+" else {
            return nil
        }

        if value.contains(where: { !$0.isNumber }) {
            return nil
        }

        guard let parsed = Int64(value), parsed >= 0 else {
            return nil
        }

        return parsed
    }
}
