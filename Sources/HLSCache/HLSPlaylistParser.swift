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

        let lines = playlist.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
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
        guard let directiveStart = line.range(of: ":")?.upperBound else {
            return nil
        }

        let attributes = parseAttributeList(String(line[directiveStart...]))
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

    private static func parseAttributeList(_ raw: String) -> [String: String] {
        var parts: [String] = []
        var current = ""
        var insideQuotes = false

        for character in raw {
            if character == "\"" {
                insideQuotes.toggle()
                current.append(character)
                continue
            }

            if character == "," && !insideQuotes {
                parts.append(current)
                current.removeAll(keepingCapacity: true)
                continue
            }

            current.append(character)
        }

        if !current.isEmpty {
            parts.append(current)
        }

        var attributes: [String: String] = [:]
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                continue
            }

            guard let equalsIndex = trimmed.firstIndex(of: "=") else {
                continue
            }

            let rawKey = trimmed[..<equalsIndex]
            let rawValue = trimmed[trimmed.index(after: equalsIndex)...]
            let key = rawKey.trimmingCharacters(in: .whitespaces).uppercased()
            guard !key.isEmpty else {
                continue
            }

            var value = rawValue.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }

            attributes[key] = value
        }

        return attributes
    }
}
