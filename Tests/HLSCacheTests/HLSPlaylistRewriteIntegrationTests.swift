import Foundation
import Testing
@testable import HLSCache

private func extractKeyURI(from directiveLine: String) -> String? {
    extractDirectiveURI(from: directiveLine)
}

private func extractDirectiveURI(from directiveLine: String) -> String? {
    let pattern = #"URI\s*=\s*"([^"]+)""#
    let regex = try? NSRegularExpression(pattern: pattern)
    let fullRange = NSRange(directiveLine.startIndex..., in: directiveLine)
    guard let match = regex?.firstMatch(in: directiveLine, range: fullRange),
          let captureRange = Range(match.range(at: 1), in: directiveLine) else {
        return nil
    }
    return String(directiveLine[captureRange])
}

@Test func playlistRewrite_smokeTest_rewritesSegmentsAndExtXKeyToLocalhostProxyRoutes() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-rewrite-smoke")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let facade = HLSCacheFacade(baseDirectory: directory)
    _ = facade.startServer(port: 18484)
    _ = try facade.register(
        alias: "MD0534",
        assetID: "asset-0534",
        remoteURL: try #require(URL(string: "https://cdn.example.com/root/master.m3u8"))
    )

    let playlistURL = try #require(URL(string: "https://cdn.example.com/root/path/media.m3u8"))
    let playlist = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-KEY:METHOD=AES-128,URI=\"keys/key-1.bin\"
    #EXTINF:4.0,
    seg-1.ts
    #EXTINF:4.0,
    https://cdn.example.com/root/path/seg-2.ts?token=abc
    #EXT-X-ENDLIST
    """

    let rewritten = try HLSPlaylistRewriter.rewrite(
        playlist,
        alias: "MD0534",
        playlistURL: playlistURL
    ) { alias, kind, remoteURL in
        try facade.proxyURL(for: alias, kind: kind, remoteURL: remoteURL)
    }

    let lines = rewritten.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let keyLine = try #require(lines.first { $0.hasPrefix("#EXT-X-KEY:") })
    let segmentLines = lines.filter { $0.hasPrefix("http://127.0.0.1:18484/MD0534/seg/") }

    #expect(lines.contains("#EXTM3U"))
    #expect(lines.contains("#EXT-X-VERSION:3"))
    #expect(lines.contains("#EXT-X-ENDLIST"))
    #expect(keyLine.contains("URI=\"http://127.0.0.1:18484/MD0534/key/"))
    #expect(segmentLines.count == 2)

    let keyURI = try #require(extractKeyURI(from: keyLine))
    let keyProxyURL = try #require(URL(string: keyURI))
    let decodedKeyRoute = try facade.decodeProxyRequestURL(keyProxyURL)
    #expect(decodedKeyRoute.kind == .key)
    #expect(decodedKeyRoute.remoteURL.absoluteString == "https://cdn.example.com/root/path/keys/key-1.bin")

    let firstSegmentProxy = try #require(URL(string: segmentLines[0]))
    let firstDecodedRoute = try facade.decodeProxyRequestURL(firstSegmentProxy)
    #expect(firstDecodedRoute.kind == .segment)
    #expect(firstDecodedRoute.remoteURL.absoluteString == "https://cdn.example.com/root/path/seg-1.ts")
}

@Test func playlistRewrite_handlesCRLF_keySpacingAndExtXMapURIRewrites() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-rewrite-crlf-map")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let facade = HLSCacheFacade(baseDirectory: directory)
    _ = facade.startServer(port: 19484)
    _ = try facade.register(
        alias: "MD0560",
        assetID: "asset-0560",
        remoteURL: try #require(URL(string: "https://cdn.example.com/r/master.m3u8"))
    )

    let playlistURL = try #require(URL(string: "https://cdn.example.com/r/media.m3u8"))
    let playlist = [
        "#EXTM3U",
        "#EXT-X-VERSION:7",
        "#EXT-X-KEY: METHOD=AES-128 , URI = \"keys/key.bin?token=a,b\"",
        "#EXT-X-MAP:URI=\"init/init.mp4\"",
        "#EXTINF:4.0,",
        "seg-1.ts",
        "#EXT-X-ENDLIST"
    ].joined(separator: "\r\n")

    let rewritten = try HLSPlaylistRewriter.rewrite(
        playlist,
        alias: "MD0560",
        playlistURL: playlistURL
    ) { alias, kind, remoteURL in
        try facade.proxyURL(for: alias, kind: kind, remoteURL: remoteURL)
    }

    let lines = rewritten.components(separatedBy: .newlines)
    let keyLine = try #require(lines.first { $0.contains("#EXT-X-KEY:") })
    let mapLine = try #require(lines.first { $0.contains("#EXT-X-MAP:") })
    let segmentLine = try #require(lines.first { $0.hasPrefix("http://127.0.0.1:19484/MD0560/seg/") })

    let keyURI = try #require(extractDirectiveURI(from: keyLine))
    let mapURI = try #require(extractDirectiveURI(from: mapLine))

    let keyRoute = try facade.decodeProxyRequestURL(try #require(URL(string: keyURI)))
    #expect(keyRoute.kind == .key)
    #expect(keyRoute.remoteURL.absoluteString == "https://cdn.example.com/r/keys/key.bin?token=a,b")

    let mapRoute = try facade.decodeProxyRequestURL(try #require(URL(string: mapURI)))
    #expect(mapRoute.kind == .segment)
    #expect(mapRoute.remoteURL.absoluteString == "https://cdn.example.com/r/init/init.mp4")

    let segmentRoute = try facade.decodeProxyRequestURL(try #require(URL(string: segmentLine)))
    #expect(segmentRoute.kind == .segment)
    #expect(segmentRoute.remoteURL.absoluteString == "https://cdn.example.com/r/seg-1.ts")
}

@Test func playlistRewrite_methodNoneKeyDirectiveIsLeftUntouched() throws {
    let playlistURL = try #require(URL(string: "https://cdn.example.com/v/master.m3u8"))
    let playlist = """
    #EXTM3U
    #EXT-X-KEY:METHOD=NONE,URI=\"keys/should-not-rewrite.bin\"
    #EXTINF:4.0,
    seg.ts
    """

    var invocations: [(kind: ProxyResourceKind, remoteURL: URL)] = []
    let rewritten = try HLSPlaylistRewriter.rewrite(
        playlist,
        alias: "MDNONE",
        playlistURL: playlistURL
    ) { _, kind, remoteURL in
        invocations.append((kind: kind, remoteURL: remoteURL))
        return try #require(URL(string: "http://127.0.0.1:9999/\(kind.rawValue)"))
    }

    #expect(rewritten.contains("#EXT-X-KEY:METHOD=NONE,URI=\"keys/should-not-rewrite.bin\""))
    #expect(invocations.count == 1)
    #expect(invocations.first?.kind == .segment)
    #expect(invocations.first?.remoteURL.absoluteString == "https://cdn.example.com/v/seg.ts")
}
