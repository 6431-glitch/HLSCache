import CoreCache
import Foundation

public enum HLSPlaylistRewriter {
    public typealias ProxyURLBuilder = (_ alias: Alias, _ kind: ProxyResourceKind, _ remoteURL: URL) throws -> URL

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
        let attributes = HLSDirectiveAttributeParser.parse(in: line, after: directivePrefix)
        guard let uriAttribute = attributes.first(where: { $0.key == "URI" }) else {
            return line
        }

        if directivePrefix == "#EXT-X-KEY:",
           let method = attributes.first(where: { $0.key == "METHOD" })?.value,
           HLSDirectiveAttributeParser.normalizeToken(method).uppercased() == "NONE" {
            return line
        }

        let normalizedURI = HLSDirectiveAttributeParser.normalizeToken(uriAttribute.value)
        guard !normalizedURI.isEmpty,
              let remoteURL = URL(string: normalizedURI, relativeTo: playlistURL)?.absoluteURL else {
            return line
        }

        let proxyURL = try proxyURLBuilder(alias, kind, remoteURL)
        var rewritten = line
        rewritten.replaceSubrange(uriAttribute.valueRange, with: proxyURL.absoluteString)
        return rewritten
    }
}
