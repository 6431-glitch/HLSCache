import Foundation

public struct HLSDirectiveAttribute: Equatable, Sendable {
    public let key: String
    public let value: String
    public let valueRange: Range<String.Index>

    public init(key: String, value: String, valueRange: Range<String.Index>) {
        self.key = key
        self.value = value
        self.valueRange = valueRange
    }
}

public enum HLSDirectiveAttributeParser {
    public enum ParseError: Error, Equatable {
        case malformedQuotedAttribute
    }

    public static func parseAfterDirectiveName(in line: String) -> [HLSDirectiveAttribute] {
        guard let directiveStart = line.range(of: ":")?.upperBound else {
            return []
        }
        return (try? parseAttributes(in: line, range: directiveStart..<line.endIndex, strict: false)) ?? []
    }

    public static func parseAfterDirectiveNameStrict(in line: String) throws -> [HLSDirectiveAttribute] {
        guard let directiveStart = line.range(of: ":")?.upperBound else {
            return []
        }
        return try parseAttributes(in: line, range: directiveStart..<line.endIndex, strict: true)
    }

    public static func parse(in line: String, after directivePrefix: String) -> [HLSDirectiveAttribute] {
        guard let attributeStart = line.range(of: directivePrefix)?.upperBound else {
            return []
        }
        return (try? parseAttributes(in: line, range: attributeStart..<line.endIndex, strict: false)) ?? []
    }

    public static func parseStrict(in line: String, after directivePrefix: String) throws -> [HLSDirectiveAttribute] {
        guard let attributeStart = line.range(of: directivePrefix)?.upperBound else {
            return []
        }
        return try parseAttributes(in: line, range: attributeStart..<line.endIndex, strict: true)
    }

    public static func attributeMap(afterDirectiveNameIn line: String) -> [String: String] {
        var attributes: [String: String] = [:]
        for attribute in parseAfterDirectiveName(in: line) {
            attributes[attribute.key] = attribute.value
        }
        return attributes
    }

    static func normalizeToken(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("\u{FEFF}") ? String(trimmed.dropFirst()) : trimmed
    }

    private static func parseAttributes(
        in line: String,
        range: Range<String.Index>,
        strict: Bool
    ) throws -> [HLSDirectiveAttribute] {
        var attributes: [HLSDirectiveAttribute] = []
        var tokenStart = range.lowerBound
        var current = range.lowerBound
        var insideQuotes = false

        while current < range.upperBound {
            let character = line[current]
            if character == "\"" {
                insideQuotes.toggle()
            } else if character == "," && !insideQuotes {
                if let attribute = try parseAttributeToken(
                    in: line,
                    range: tokenStart..<current,
                    strict: strict
                ) {
                    attributes.append(attribute)
                }
                tokenStart = line.index(after: current)
            }
            current = line.index(after: current)
        }

        if insideQuotes, strict {
            throw ParseError.malformedQuotedAttribute
        }

        if let attribute = try parseAttributeToken(
            in: line,
            range: tokenStart..<range.upperBound,
            strict: strict
        ) {
            attributes.append(attribute)
        }

        return attributes
    }

    private static func parseAttributeToken(
        in line: String,
        range: Range<String.Index>,
        strict: Bool
    ) throws -> HLSDirectiveAttribute? {
        guard let trimmedToken = trimmedRange(in: line, range: range),
              let equalsIndex = line[trimmedToken].firstIndex(of: "=") else {
            return nil
        }

        guard let keyRange = trimmedRange(in: line, range: trimmedToken.lowerBound..<equalsIndex) else {
            return nil
        }
        let rawValueSpan = line.index(after: equalsIndex)..<trimmedToken.upperBound
        let rawValueRange = trimmedRange(in: line, range: rawValueSpan)
            ?? rawValueSpan.lowerBound..<rawValueSpan.lowerBound

        let key = normalizeToken(String(line[keyRange])).uppercased()
        guard !key.isEmpty else {
            return nil
        }

        let rawValue = line[rawValueRange]
        let startsQuoted = rawValue.first == "\""
        let endsQuoted = rawValue.last == "\""
        if startsQuoted != endsQuoted {
            if strict {
                throw ParseError.malformedQuotedAttribute
            }
            return nil
        }

        let valueRange: Range<String.Index>
        if startsQuoted,
           line.distance(from: rawValueRange.lowerBound, to: rawValueRange.upperBound) >= 2 {
            let start = line.index(after: rawValueRange.lowerBound)
            let end = line.index(before: rawValueRange.upperBound)
            valueRange = start..<end
        } else {
            valueRange = rawValueRange
        }

        return HLSDirectiveAttribute(
            key: key,
            value: normalizeToken(String(line[valueRange])),
            valueRange: valueRange
        )
    }

    private static func trimmedRange(in line: String, range: Range<String.Index>) -> Range<String.Index>? {
        var lower = range.lowerBound
        var upper = range.upperBound

        while lower < upper, line[lower].isWhitespace {
            lower = line.index(after: lower)
        }

        while upper > lower {
            let previous = line.index(before: upper)
            if line[previous].isWhitespace {
                upper = previous
            } else {
                break
            }
        }

        guard lower < upper else {
            return nil
        }
        return lower..<upper
    }
}
