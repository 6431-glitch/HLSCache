import CoreCache
import Foundation
import Testing
@testable import HLSCache

@Test func hlsDownloadPlanner_buildsFullPlanAndRewritesMediaPlaylistURLsToProxyRoutes() throws {
    let rootURL = try #require(URL(string: "https://cdn.example.com/root/master.m3u8"))
    let mediaURL = try #require(URL(string: "https://cdn.example.com/root/v1/media.m3u8"))

    let playlists: [URL: String] = [
        rootURL: """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1500000
        v1/media.m3u8
        """,
        mediaURL: """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-KEY:METHOD=AES-128,URI="../keys/main.key"
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4.0,
        seg-1.ts
        #EXTINF:4.0,
        seg-2.ts
        #EXT-X-ENDLIST
        """
    ]

    var rewriteInvocations: [(kind: ProxyResourceKind, remoteURL: URL)] = []
    let plan = try HLSDownloadPlanner.plan(
        rootPlaylistURL: rootURL,
        alias: "MDP54",
        loadPlaylist: { url in
            try #require(playlists[url])
        },
        proxyURLBuilder: { alias, kind, remoteURL in
            rewriteInvocations.append((kind: kind, remoteURL: remoteURL))
            let encoded = ResourceID.makeResourceKey(from: remoteURL)
            return try #require(URL(string: "http://127.0.0.1:8080/\(alias)/\(kind.rawValue)/\(encoded)"))
        }
    )

    #expect(plan.playlistURLs.count == 2)
    #expect(plan.segmentURLs.count == 2)
    #expect(plan.mapURLs.count == 1)
    #expect(plan.keyURLs.count == 1)
    #expect(plan.totalResourceCount == 6)

    #expect(plan.segmentURLs[0].absoluteString == "https://cdn.example.com/root/v1/seg-1.ts")
    #expect(plan.mapURLs[0].absoluteString == "https://cdn.example.com/root/v1/init.mp4")
    #expect(plan.keyURLs[0].absoluteString == "https://cdn.example.com/root/keys/main.key")

    let mediaPlan = try #require(plan.playlists.first { $0.remoteURL == mediaURL })
    #expect(mediaPlan.rewrittenPlaylist.contains("http://127.0.0.1:8080/MDP54/key/"))
    #expect(mediaPlan.rewrittenPlaylist.contains("http://127.0.0.1:8080/MDP54/seg/"))
    #expect(rewriteInvocations.contains { $0.kind == .key && $0.remoteURL.absoluteString == "https://cdn.example.com/root/keys/main.key" })
}

@Test func hlsDownloadPlanner_methodNoneKeyIsIgnoredForDownloadPlanAndRewriter() throws {
    let rootURL = try #require(URL(string: "https://cdn.example.com/live/media.m3u8"))
    let playlist = """
    #EXTM3U
    #EXT-X-KEY:METHOD=NONE,URI="keys/ignored.key"
    #EXTINF:4.0,
    seg-1.ts
    #EXT-X-ENDLIST
    """

    var rewriteInvocations: [(kind: ProxyResourceKind, remoteURL: URL)] = []
    let plan = try HLSDownloadPlanner.plan(
        rootPlaylistURL: rootURL,
        alias: "MDNONE",
        loadPlaylist: { _ in playlist },
        proxyURLBuilder: { alias, kind, remoteURL in
            rewriteInvocations.append((kind: kind, remoteURL: remoteURL))
            let encoded = ResourceID.makeResourceKey(from: remoteURL)
            return try #require(URL(string: "http://127.0.0.1:9000/\(alias)/\(kind.rawValue)/\(encoded)"))
        }
    )

    #expect(plan.keyURLs.isEmpty)
    #expect(plan.segmentURLs.count == 1)

    let playlistPlan = try #require(plan.playlists.first)
    #expect(playlistPlan.rewrittenPlaylist.contains(#"#EXT-X-KEY:METHOD=NONE,URI="keys/ignored.key""#))
    #expect(!rewriteInvocations.contains { $0.kind == .key })
}

@Test func hlsDownloadPlanner_deduplicatesSharedSegmentAndKeyAcrossPlaylists() throws {
    let rootURL = try #require(URL(string: "https://cdn.example.com/a/master.m3u8"))
    let media1URL = try #require(URL(string: "https://cdn.example.com/a/v1.m3u8"))
    let media2URL = try #require(URL(string: "https://cdn.example.com/a/v2.m3u8"))

    let playlists: [URL: String] = [
        rootURL: """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000000
        v1.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=900000
        v2.m3u8
        """,
        media1URL: """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="keys/shared.key"
        #EXTINF:4.0,
        shared.ts
        """,
        media2URL: """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="keys/shared.key"
        #EXTINF:4.0,
        shared.ts
        """
    ]

    let plan = try HLSDownloadPlanner.plan(
        rootPlaylistURL: rootURL,
        alias: "MDSHARED",
        loadPlaylist: { url in
            try #require(playlists[url])
        },
        proxyURLBuilder: { alias, kind, remoteURL in
            let encoded = ResourceID.makeResourceKey(from: remoteURL)
            return try #require(URL(string: "http://127.0.0.1:9100/\(alias)/\(kind.rawValue)/\(encoded)"))
        }
    )

    #expect(plan.playlistURLs.count == 3)
    #expect(plan.segmentURLs.count == 1)
    #expect(plan.keyURLs.count == 1)
}

@Test func hlsDownloadPlanner_deduplicatesCanonicalURLVariants() throws {
    let rootURL = try #require(URL(string: "https://cdn.example.com/master.m3u8"))
    let mediaURL = try #require(URL(string: "https://cdn.example.com/v1/media.m3u8"))

    let playlists: [URL: String] = [
        rootURL: """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000000
        v1/media.m3u8
        """,
        mediaURL: """
        #EXTM3U
        #EXTINF:4.0,
        https://cdn.example.com:443/content/./seg.ts?b=2&a=1
        #EXTINF:4.0,
        https://CDN.example.com/content/seg.ts?a=1&b=2#ignored
        """
    ]

    let plan = try HLSDownloadPlanner.plan(
        rootPlaylistURL: rootURL,
        alias: "MDCANON",
        loadPlaylist: { url in
            try #require(playlists[url])
        },
        proxyURLBuilder: { alias, kind, remoteURL in
            let encoded = ResourceID.makeResourceKey(from: remoteURL)
            return try #require(URL(string: "http://127.0.0.1:9090/\(alias)/\(kind.rawValue)/\(encoded)"))
        }
    )

    #expect(plan.segmentURLs.count == 1)
}

@Test func hlsDownloadPlanner_canonicalizationPolicy_preservesRepeatedQueryOrderException() throws {
    let rootURL = try #require(URL(string: "https://cdn.example.com/master.m3u8"))
    let mediaURL = try #require(URL(string: "https://cdn.example.com/v1/media.m3u8"))

    let playlists: [URL: String] = [
        rootURL: """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000000
        v1/media.m3u8
        """,
        mediaURL: """
        #EXTM3U
        #EXTINF:4.0,
        https://cdn.example.com/content/seg.ts?token=a&token=b
        #EXTINF:4.0,
        https://cdn.example.com/content/seg.ts?token=b&token=a
        """
    ]

    let plan = try HLSDownloadPlanner.plan(
        rootPlaylistURL: rootURL,
        alias: "MDCANONEX",
        loadPlaylist: { url in
            try #require(playlists[url])
        },
        proxyURLBuilder: { alias, kind, remoteURL in
            let encoded = ResourceID.makeResourceKey(from: remoteURL)
            return try #require(URL(string: "http://127.0.0.1:9091/\(alias)/\(kind.rawValue)/\(encoded)"))
        }
    )

    #expect(plan.segmentURLs.count == 2)
}

@Test func hlsDownloadPlanner_resolvesURIAttributes_withSpacingVariantsForMediaAndMap() throws {
    let rootURL = try #require(URL(string: "https://cdn.example.com/root/master.m3u8"))
    let videoURL = try #require(URL(string: "https://cdn.example.com/root/video/main.m3u8"))
    let audioURL = try #require(URL(string: "https://cdn.example.com/root/audio/audio.m3u8"))

    let playlists: [URL: String] = [
        rootURL: """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="en",URI = " audio/audio.m3u8 "
        #EXT-X-STREAM-INF:BANDWIDTH=1000000
        video/main.m3u8
        """,
        videoURL: """
        #EXTM3U
        #EXT-X-MAP: URI = " init/init.mp4 "
        #EXTINF:4.0,
        seg-1.ts
        """,
        audioURL: """
        #EXTM3U
        #EXTINF:4.0,
        audio-1.ts
        """
    ]

    let plan = try HLSDownloadPlanner.plan(
        rootPlaylistURL: rootURL,
        alias: "MDURI",
        loadPlaylist: { url in
            try #require(playlists[url])
        },
        proxyURLBuilder: { alias, kind, remoteURL in
            let encoded = ResourceID.makeResourceKey(from: remoteURL)
            return try #require(URL(string: "http://127.0.0.1:8081/\(alias)/\(kind.rawValue)/\(encoded)"))
        }
    )

    #expect(plan.playlistURLs.count == 3)
    #expect(plan.playlistURLs.contains(audioURL))
    #expect(plan.playlistURLs.contains(videoURL))
    #expect(plan.mapURLs.count == 1)
    #expect(plan.mapURLs[0].absoluteString == "https://cdn.example.com/root/video/init/init.mp4")
}

@Test func hlsDownloadPlanner_ignoresMalformedURIAttributes_withoutCrashingOrRegressingOtherDiscovery() throws {
    let rootURL = try #require(URL(string: "https://cdn.example.com/root/master.m3u8"))
    let videoURL = try #require(URL(string: "https://cdn.example.com/root/video/main.m3u8"))

    let playlists: [URL: String] = [
        rootURL: """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="en",URI = "http://[broken"
        #EXT-X-STREAM-INF:BANDWIDTH=1000000
        video/main.m3u8
        """,
        videoURL: """
        #EXTM3U
        #EXT-X-MAP:URI = "http://[also-broken"
        #EXTINF:4.0,
        seg-1.ts
        """
    ]

    let plan = try HLSDownloadPlanner.plan(
        rootPlaylistURL: rootURL,
        alias: "MDMAL",
        loadPlaylist: { url in
            try #require(playlists[url])
        },
        proxyURLBuilder: { alias, kind, remoteURL in
            let encoded = ResourceID.makeResourceKey(from: remoteURL)
            return try #require(URL(string: "http://127.0.0.1:8082/\(alias)/\(kind.rawValue)/\(encoded)"))
        }
    )

    #expect(plan.playlistURLs.count == 2)
    #expect(plan.playlistURLs.contains(videoURL))
    #expect(plan.mapURLs.isEmpty)
    #expect(plan.segmentURLs.count == 1)
    #expect(plan.segmentURLs[0].absoluteString == "https://cdn.example.com/root/video/seg-1.ts")
}

@Test func hlsDownloadPlanner_uriAttributeVariants_stayConsistentAcrossPlannerAndRewriter() throws {
    let rootURL = try #require(URL(string: "https://cdn.example.com/root/master.m3u8"))
    let mediaURL = try #require(URL(string: "https://cdn.example.com/root/video/main.m3u8"))
    let audioURL = try #require(URL(string: "https://cdn.example.com/audio/en.m3u8"))

    let playlists: [URL: String] = [
        rootURL: """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="en",URI\t=\t" ../audio/en.m3u8 "
        #EXT-X-STREAM-INF:BANDWIDTH=1200000
        video/main.m3u8
        """,
        mediaURL: """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,\tURI\t=\t" ../keys/media.key "
        #EXT-X-MAP:BYTERANGE="900@0", URI\t=\t" ./init/video-init.mp4 "
        #EXTINF:4.0,
        seg-1.ts
        """,
        audioURL: """
        #EXTM3U
        #EXTINF:4.0,
        audio-1.ts
        """
    ]

    var rewriteInvocations: [(kind: ProxyResourceKind, remoteURL: URL)] = []
    let plan = try HLSDownloadPlanner.plan(
        rootPlaylistURL: rootURL,
        alias: "MDURIVAR",
        loadPlaylist: { url in
            try #require(playlists[url])
        },
        proxyURLBuilder: { alias, kind, remoteURL in
            rewriteInvocations.append((kind: kind, remoteURL: remoteURL))
            let encoded = ResourceID.makeResourceKey(from: remoteURL)
            return try #require(URL(string: "http://127.0.0.1:8083/\(alias)/\(kind.rawValue)/\(encoded)"))
        }
    )

    let expectedMapURL = try #require(URL(string: "https://cdn.example.com/root/video/init/video-init.mp4"))
    let expectedKeyURL = try #require(URL(string: "https://cdn.example.com/root/keys/media.key"))

    #expect(plan.playlistURLs.count == 3)
    #expect(plan.playlistURLs.contains(audioURL))
    #expect(plan.mapURLs == [expectedMapURL])
    #expect(plan.keyURLs == [expectedKeyURL])

    let mediaPlan = try #require(plan.playlists.first { $0.remoteURL == mediaURL })
    #expect(mediaPlan.mapURLs == [expectedMapURL])
    #expect(mediaPlan.keyURLs == [expectedKeyURL])
    #expect(mediaPlan.rewrittenPlaylist.contains("/MDURIVAR/key/"))
    #expect(mediaPlan.rewrittenPlaylist.contains("/MDURIVAR/seg/"))
    #expect(rewriteInvocations.contains { $0.kind == .key && $0.remoteURL == expectedKeyURL })
    #expect(rewriteInvocations.contains { $0.kind == .segment && $0.remoteURL == expectedMapURL })
}

@Test func hlsDownloadPlanner_malformedURIAttributeTokens_areIgnoredSafely() throws {
    let rootURL = try #require(URL(string: "https://cdn.example.com/root/master.m3u8"))
    let mediaURL = try #require(URL(string: "https://cdn.example.com/root/video/main.m3u8"))

    let playlists: [URL: String] = [
        rootURL: """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="en",URI
        #EXT-X-STREAM-INF:BANDWIDTH=1000000
        video/main.m3u8
        """,
        mediaURL: """
        #EXTM3U
        #EXT-X-MAP:URI = "unterminated
        #EXTINF:4.0,
        seg-1.ts
        """
    ]

    let plan = try HLSDownloadPlanner.plan(
        rootPlaylistURL: rootURL,
        alias: "MDURIMAL",
        loadPlaylist: { url in
            try #require(playlists[url])
        },
        proxyURLBuilder: { alias, kind, remoteURL in
            let encoded = ResourceID.makeResourceKey(from: remoteURL)
            return try #require(URL(string: "http://127.0.0.1:8084/\(alias)/\(kind.rawValue)/\(encoded)"))
        }
    )

    #expect(plan.playlistURLs.count == 2)
    #expect(plan.playlistURLs.contains(mediaURL))
    #expect(plan.mapURLs.isEmpty)
    #expect(plan.segmentURLs.count == 1)
    #expect(plan.segmentURLs[0].absoluteString == "https://cdn.example.com/root/video/seg-1.ts")
}
