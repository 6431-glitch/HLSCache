import Foundation
import Testing
@testable import HLSCache

private func extractKeyURI(from directiveLine: String) -> String? {
    guard let uriStart = directiveLine.range(of: "URI=\"")?.upperBound else {
        return nil
    }
    guard let uriEnd = directiveLine[uriStart...].firstIndex(of: "\"") else {
        return nil
    }
    return String(directiveLine[uriStart..<uriEnd])
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
