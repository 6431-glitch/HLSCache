import CoreCache
import Foundation

public enum HLSPlaylistRewriter {
    public typealias ProxyURLBuilder = (_ alias: Alias, _ kind: ProxyResourceKind, _ remoteURL: URL) throws -> URL

    private struct DirectiveAttribute {
        let key: String
        let value: String
        let valueRange: Range<String.Index>
    }

    public static func rewrite(
        _ playlist: String,
        alias: Alias,
        playlistURL: URL,
        proxyURLBuilder: ProxyURLBuilder
    ) throws -> String {
        let separatorRegex = try NSRegularExpression(pattern: "\r\n|\n|\r")
        let fullRange = NSRange(playlist.startIndex..<playlist.endIndex, in: playlist)
        let matches = separatorRegex.matches(in: playlist, range: fullRange)

        var output = ""
        var lineStart = playlist.startIndex
        for match in matches {
            guard let separatorRange = Range(match.range, in: playlist) else {
                continue
            }
            let line = String(playlist[lineStart..<separatorRange.lowerBound])
            output += try rewriteLine(line, alias: alias, playlistURL: playlistURL, proxyURLBuilder: proxyURLBuilder)
            output += String(playlist[separatorRange])
            lineStart = separatorRange.upperBound
        }

        let tail = String(playlist[lineStart...])
        output += try rewriteLine(tail, alias: alias, playlistURL: playlistURL, proxyURLBuilder: proxyURLBuilder)
        return output
    }

    private static func rewriteLine(
        _ line: String,
        alias: Alias,
        playlistURL: URL,
        proxyURLBuilder: ProxyURLBuilder
    ) throws -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("#EXT-X-KEY:") {
            return try rewriteDirectiveURI(
                line,
                directivePrefix: "#EXT-X-KEY:",
                alias: alias,
                kind: .key,
                playlistURL: playlistURL,
                proxyURLBuilder: proxyURLBuilder
            )
        }

        if trimmed.hasPrefix("#EXT-X-MAP:") {
            return try rewriteDirectiveURI(
                line,
                directivePrefix: "#EXT-X-MAP:",
                alias: alias,
                kind: .segment,
                playlistURL: playlistURL,
                proxyURLBuilder: proxyURLBuilder
            )
        }

        if trimmed.isEmpty || trimmed.hasPrefix("#") {
            return line
        }

        guard let remoteURL = URL(string: trimmed, relativeTo: playlistURL)?.absoluteURL else {
            return line
        }

        let proxyURL = try proxyURLBuilder(alias, .segment, remoteURL)
        return proxyURL.absoluteString
    }

    private static func rewriteDirectiveURI(
        _ line: String,
        directivePrefix: String,
        alias: Alias,
        kind: ProxyResourceKind,
        playlistURL: URL,
        proxyURLBuilder: ProxyURLBuilder
    ) throws -> String {
        guard let attributeStart = line.range(of: directivePrefix)?.upperBound else {
            return line
        }
        let attributes = parseDirectiveAttributes(in: line, range: attributeStart..<line.endIndex)
        guard let uriAttribute = attributes.first(where: { $0.key == "URI" }) else {
            return line
        }

        if directivePrefix == "#EXT-X-KEY:",
           let method = attributes.first(where: { $0.key == "METHOD" })?.value,
           normalizeToken(method).uppercased() == "NONE" {
            return line
        }

        let normalizedURI = normalizeToken(uriAttribute.value)
        guard !normalizedURI.isEmpty,
              let remoteURL = URL(string: normalizedURI, relativeTo: playlistURL)?.absoluteURL else {
            return line
        }

        let proxyURL = try proxyURLBuilder(alias, kind, remoteURL)
        var rewritten = line
        rewritten.replaceSubrange(uriAttribute.valueRange, with: proxyURL.absoluteString)
        return rewritten
    }

    private static func parseDirectiveAttributes(in line: String, range: Range<String.Index>) -> [DirectiveAttribute] {
        var attributes: [DirectiveAttribute] = []
        var tokenStart = range.lowerBound
        var current = range.lowerBound
        var insideQuotes = false

        while current < range.upperBound {
            let character = line[current]
            if character == "\"" {
                insideQuotes.toggle()
            } else if character == "," && !insideQuotes {
                if let attribute = parseAttributeToken(in: line, range: tokenStart..<current) {
                    attributes.append(attribute)
                }
                tokenStart = line.index(after: current)
            }
            current = line.index(after: current)
        }

        if let attribute = parseAttributeToken(in: line, range: tokenStart..<range.upperBound) {
            attributes.append(attribute)
        }

        return attributes
    }

    private static func parseAttributeToken(in line: String, range: Range<String.Index>) -> DirectiveAttribute? {
        guard let trimmedToken = trimmedRange(in: line, range: range),
              let equalsIndex = line[trimmedToken].firstIndex(of: "=") else {
            return nil
        }

        guard let keyRange = trimmedRange(in: line, range: trimmedToken.lowerBound..<equalsIndex),
              let rawValueRange = trimmedRange(
                  in: line,
                  range: line.index(after: equalsIndex)..<trimmedToken.upperBound
              ) else {
            return nil
        }

        let key = String(line[keyRange]).uppercased()
        guard !key.isEmpty else {
            return nil
        }

        let rawValue = line[rawValueRange]
        let startsQuoted = rawValue.first == "\""
        let endsQuoted = rawValue.last == "\""
        if startsQuoted != endsQuoted {
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

        return DirectiveAttribute(
            key: key,
            value: String(line[valueRange]),
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

    private static func normalizeToken(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("\u{FEFF}") ? String(trimmed.dropFirst()) : trimmed
    }
}
