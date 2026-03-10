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
        let lines = playlist.split(separator: "\n", omittingEmptySubsequences: false)
        let rewritten = try lines.map { line in
            try rewriteLine(String(line), alias: alias, playlistURL: playlistURL, proxyURLBuilder: proxyURLBuilder)
        }
        return rewritten.joined(separator: "\n")
    }

    private static func rewriteLine(
        _ line: String,
        alias: Alias,
        playlistURL: URL,
        proxyURLBuilder: ProxyURLBuilder
    ) throws -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("#EXT-X-KEY:") {
            return try rewriteKeyDirective(
                line,
                alias: alias,
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

    private static func rewriteKeyDirective(
        _ line: String,
        alias: Alias,
        playlistURL: URL,
        proxyURLBuilder: ProxyURLBuilder
    ) throws -> String {
        guard let uriStart = line.range(of: "URI=\"")?.upperBound else {
            return line
        }
        guard let uriEnd = line[uriStart...].firstIndex(of: "\"") else {
            return line
        }

        let uriValue = String(line[uriStart..<uriEnd])
        guard let remoteURL = URL(string: uriValue, relativeTo: playlistURL)?.absoluteURL else {
            return line
        }

        let proxyURL = try proxyURLBuilder(alias, .key, remoteURL)
        var rewritten = line
        rewritten.replaceSubrange(uriStart..<uriEnd, with: proxyURL.absoluteString)
        return rewritten
    }
}
