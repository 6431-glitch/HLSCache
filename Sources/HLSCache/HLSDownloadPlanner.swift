import CoreCache
import Foundation

public struct HLSPlannedPlaylist: Equatable, Sendable {
    public let remoteURL: URL
    public let originalPlaylist: String
    public let rewrittenPlaylist: String
    public let childPlaylistURLs: [URL]
    public let segmentURLs: [URL]
    public let mapURLs: [URL]
    public let keyURLs: [URL]

    public init(
        remoteURL: URL,
        originalPlaylist: String,
        rewrittenPlaylist: String,
        childPlaylistURLs: [URL],
        segmentURLs: [URL],
        mapURLs: [URL],
        keyURLs: [URL]
    ) {
        self.remoteURL = remoteURL
        self.originalPlaylist = originalPlaylist
        self.rewrittenPlaylist = rewrittenPlaylist
        self.childPlaylistURLs = childPlaylistURLs
        self.segmentURLs = segmentURLs
        self.mapURLs = mapURLs
        self.keyURLs = keyURLs
    }
}

public struct HLSDownloadPlan: Equatable, Sendable {
    public let rootPlaylistURL: URL
    public let playlists: [HLSPlannedPlaylist]
    public let playlistURLs: [URL]
    public let segmentURLs: [URL]
    public let mapURLs: [URL]
    public let keyURLs: [URL]

    public var totalResourceCount: Int {
        playlistURLs.count + segmentURLs.count + mapURLs.count + keyURLs.count
    }

    public init(
        rootPlaylistURL: URL,
        playlists: [HLSPlannedPlaylist],
        playlistURLs: [URL],
        segmentURLs: [URL],
        mapURLs: [URL],
        keyURLs: [URL]
    ) {
        self.rootPlaylistURL = rootPlaylistURL
        self.playlists = playlists
        self.playlistURLs = playlistURLs
        self.segmentURLs = segmentURLs
        self.mapURLs = mapURLs
        self.keyURLs = keyURLs
    }
}

public enum HLSDownloadPlanner {
    public typealias PlaylistLoader = (_ playlistURL: URL) throws -> String

    public static func plan(
        rootPlaylistURL: URL,
        alias: Alias,
        loadPlaylist: PlaylistLoader,
        proxyURLBuilder: HLSPlaylistRewriter.ProxyURLBuilder
    ) throws -> HLSDownloadPlan {
        var pendingPlaylists: [URL] = [rootPlaylistURL]
        var visitedPlaylists: Set<String> = []

        var plannedPlaylists: [HLSPlannedPlaylist] = []
        var playlistURLs: [URL] = []
        var segmentURLs: [URL] = []
        var mapURLs: [URL] = []
        var keyURLs: [URL] = []

        var playlistSeen: Set<String> = []
        var segmentSeen: Set<String> = []
        var mapSeen: Set<String> = []
        var keySeen: Set<String> = []

        while !pendingPlaylists.isEmpty {
            let playlistURL = pendingPlaylists.removeFirst()
            let canonicalPlaylist = canonicalURLKey(for: playlistURL)
            guard visitedPlaylists.insert(canonicalPlaylist).inserted else {
                continue
            }

            let playlist = try loadPlaylist(playlistURL)
            let parsed = HLSPlaylistParser.parse(playlist, playlistURL: playlistURL)
            let parsedMapURLs = try extractMapRemoteURLs(from: playlist, playlistURL: playlistURL)
            let extractedChildren = try extractChildPlaylistURLs(from: playlist, playlistURL: playlistURL)

            var childPlaylistURLs = extractedChildren
            var mediaSegmentURLs: [URL] = []
            for segmentURL in parsed.segments.map(\.remoteURL) {
                if looksLikePlaylistURL(segmentURL) {
                    childPlaylistURLs.append(segmentURL)
                } else {
                    mediaSegmentURLs.append(segmentURL)
                }
            }
            childPlaylistURLs = deduplicatedURLs(childPlaylistURLs)

            let parsedKeyURLs = parsed.keys
                .filter { $0.method?.uppercased() != "NONE" }
                .map(\.remoteURL)

            let rewrittenPlaylist: String
            if playlist.contains("#EXTINF") || playlist.contains("#EXT-X-MAP") || playlist.contains("#EXT-X-KEY") {
                rewrittenPlaylist = try HLSPlaylistRewriter.rewrite(
                    playlist,
                    alias: alias,
                    playlistURL: playlistURL,
                    proxyURLBuilder: proxyURLBuilder
                )
            } else {
                rewrittenPlaylist = playlist
            }

            plannedPlaylists.append(
                HLSPlannedPlaylist(
                    remoteURL: playlistURL,
                    originalPlaylist: playlist,
                    rewrittenPlaylist: rewrittenPlaylist,
                    childPlaylistURLs: childPlaylistURLs,
                    segmentURLs: mediaSegmentURLs,
                    mapURLs: parsedMapURLs,
                    keyURLs: parsedKeyURLs
                )
            )

            appendUnique(url: playlistURL, seen: &playlistSeen, output: &playlistURLs)
            for url in mediaSegmentURLs {
                appendUnique(url: url, seen: &segmentSeen, output: &segmentURLs)
            }
            for url in parsedMapURLs {
                appendUnique(url: url, seen: &mapSeen, output: &mapURLs)
            }
            for url in parsedKeyURLs {
                appendUnique(url: url, seen: &keySeen, output: &keyURLs)
            }

            for childURL in childPlaylistURLs {
                let childKey = canonicalURLKey(for: childURL)
                if !visitedPlaylists.contains(childKey) {
                    pendingPlaylists.append(childURL)
                }
            }
        }

        return HLSDownloadPlan(
            rootPlaylistURL: rootPlaylistURL,
            playlists: plannedPlaylists,
            playlistURLs: playlistURLs,
            segmentURLs: segmentURLs,
            mapURLs: mapURLs,
            keyURLs: keyURLs
        )
    }

    private static func extractChildPlaylistURLs(from playlist: String, playlistURL: URL) throws -> [URL] {
        let lines = playlist.components(separatedBy: .newlines)
        var urls: [URL] = []

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            if trimmed.hasPrefix("#EXT-X-MEDIA"),
               let mediaURL = try resolveURIAttribute(in: line, relativeTo: playlistURL) {
                urls.append(mediaURL)
                continue
            }

            if trimmed.hasPrefix("#EXT-X-STREAM-INF") {
                var nextIndex = index + 1
                while nextIndex < lines.count {
                    let candidate = lines[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                    nextIndex += 1
                    guard !candidate.isEmpty else {
                        continue
                    }
                    if candidate.hasPrefix("#") {
                        continue
                    }
                    guard let childURL = URL(string: candidate, relativeTo: playlistURL)?.absoluteURL else {
                        break
                    }
                    urls.append(childURL)
                    break
                }
                continue
            }

            if trimmed.hasPrefix("#") {
                continue
            }

            if looksLikePlaylistPath(trimmed),
               let childURL = URL(string: trimmed, relativeTo: playlistURL)?.absoluteURL {
                urls.append(childURL)
            }
        }

        return deduplicatedURLs(urls)
    }

    private static func extractMapRemoteURLs(from playlist: String, playlistURL: URL) throws -> [URL] {
        var urls: [URL] = []
        for line in playlist.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("#EXT-X-MAP") else {
                continue
            }
            if let mapURL = try resolveURIAttribute(in: line, relativeTo: playlistURL) {
                urls.append(mapURL)
            }
        }
        return deduplicatedURLs(urls)
    }

    private static func resolveURIAttribute(in line: String, relativeTo baseURL: URL) throws -> URL? {
        let attributes = HLSDirectiveAttributeParser.attributeMap(afterDirectiveNameIn: line)
        guard let rawURI = attributes["URI"], !rawURI.isEmpty else {
            return nil
        }
        return URL(string: rawURI, relativeTo: baseURL)?.absoluteURL
    }

    private static func appendUnique(url: URL, seen: inout Set<String>, output: inout [URL]) {
        let key = canonicalURLKey(for: url)
        guard seen.insert(key).inserted else {
            return
        }
        output.append(url)
    }

    private static func deduplicatedURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var output: [URL] = []
        for url in urls {
            appendUnique(url: url, seen: &seen, output: &output)
        }
        return output
    }

    // Planner dedup identity follows the same canonicalization policy as ResourceID:
    // - normalize scheme/host case, default ports, path normalization, and query key ordering
    // - preserve repeated query key value order as a deliberate identity exception
    // This keeps planner output deterministic while avoiding over-collapsing semantically distinct URLs.
    private static func canonicalURLKey(for url: URL) -> String {
        ResourceID.makeResourceKey(from: url)
    }

    private static func looksLikePlaylistURL(_ url: URL) -> Bool {
        url.absoluteString.lowercased().contains(".m3u8")
    }

    private static func looksLikePlaylistPath(_ raw: String) -> Bool {
        raw.lowercased().contains(".m3u8")
    }
}
