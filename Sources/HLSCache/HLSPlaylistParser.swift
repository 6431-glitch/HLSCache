import CoreCache
import Foundation

public struct HLSPlaylistSegment: Equatable, Sendable {
    public let lineNumber: Int
    public let uri: String
    public let remoteURL: URL

    public init(lineNumber: Int, uri: String, remoteURL: URL) {
        self.lineNumber = lineNumber
        self.uri = uri
        self.remoteURL = remoteURL
    }
}

public struct HLSPlaylistKey: Equatable, Sendable {
    public let lineNumber: Int
    public let method: String?
    public let uri: String
    public let remoteURL: URL

    public init(lineNumber: Int, method: String?, uri: String, remoteURL: URL) {
        self.lineNumber = lineNumber
        self.method = method
        self.uri = uri
        self.remoteURL = remoteURL
    }
}

public struct HLSPlaylistParseResult: Equatable, Sendable {
    public let segments: [HLSPlaylistSegment]
    public let keys: [HLSPlaylistKey]

    public init(segments: [HLSPlaylistSegment], keys: [HLSPlaylistKey]) {
        self.segments = segments
        self.keys = keys
    }
}

public enum HLSPlaylistParser {
    public static func parse(_ playlist: String, playlistURL: URL) -> HLSPlaylistParseResult {
        var segments: [HLSPlaylistSegment] = []
        var keys: [HLSPlaylistKey] = []

        let lines = playlist.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            let trimmed = HLSDirectiveAttributeParser.normalizeToken(line)
            guard !trimmed.isEmpty else {
                continue
            }

            if trimmed.hasPrefix("#EXT-X-KEY:") {
                guard let key = parseKeyLine(trimmed, lineNumber: index + 1, playlistURL: playlistURL) else {
                    continue
                }
                keys.append(key)
                continue
            }

            if trimmed.hasPrefix("#") {
                continue
            }

            guard let remoteURL = URL(string: trimmed, relativeTo: playlistURL)?.absoluteURL else {
                continue
            }

            segments.append(
                HLSPlaylistSegment(
                    lineNumber: index + 1,
                    uri: trimmed,
                    remoteURL: remoteURL
                )
            )
        }

        return HLSPlaylistParseResult(segments: segments, keys: keys)
    }

    private static func parseKeyLine(_ line: String, lineNumber: Int, playlistURL: URL) -> HLSPlaylistKey? {
        let attributes = HLSDirectiveAttributeParser.attributeMap(afterDirectiveNameIn: line)
        guard let rawURI = attributes["URI"], !rawURI.isEmpty else {
            return nil
        }
        guard let remoteURL = URL(string: rawURI, relativeTo: playlistURL)?.absoluteURL else {
            return nil
        }

        return HLSPlaylistKey(
            lineNumber: lineNumber,
            method: attributes["METHOD"],
            uri: rawURI,
            remoteURL: remoteURL
        )
    }
}
