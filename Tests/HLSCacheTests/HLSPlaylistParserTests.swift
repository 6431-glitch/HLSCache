import Foundation
import Testing
@testable import HLSCache

@Test func playlistParser_extractsSegmentsAndKeys_withRelativeAndAbsoluteURLs() throws {
    let playlistURL = try #require(URL(string: "https://cdn.example.com/video/path/master.m3u8"))
    let playlist = """
    #EXTM3U
    #EXT-X-VERSION:6
    #EXT-X-KEY:METHOD=AES-128,URI=\"keys/key-1.bin\"
    #EXTINF:4.0,
    seg-1.ts
    #EXTINF:4.0,
    https://cdn2.example.com/video/path/seg-2.ts
    """

    let result = HLSPlaylistParser.parse(playlist, playlistURL: playlistURL)

    #expect(result.keys.count == 1)
    #expect(result.segments.count == 2)

    let key = try #require(result.keys.first)
    #expect(key.lineNumber == 3)
    #expect(key.method == "AES-128")
    #expect(key.uri == "keys/key-1.bin")
    #expect(key.remoteURL.absoluteString == "https://cdn.example.com/video/path/keys/key-1.bin")

    #expect(result.segments[0].lineNumber == 5)
    #expect(result.segments[0].uri == "seg-1.ts")
    #expect(result.segments[0].remoteURL.absoluteString == "https://cdn.example.com/video/path/seg-1.ts")

    #expect(result.segments[1].lineNumber == 7)
    #expect(result.segments[1].uri == "https://cdn2.example.com/video/path/seg-2.ts")
    #expect(result.segments[1].remoteURL.absoluteString == "https://cdn2.example.com/video/path/seg-2.ts")
}

@Test func playlistParser_ignoresInvalidOrNonRewritableEntries() throws {
    let playlistURL = try #require(URL(string: "https://cdn.example.com/root/media.m3u8"))
    let playlist = """
    #EXTM3U
    #EXT-X-KEY:METHOD=NONE
    #EXTINF:4.0,
    seg-1.ts
    #EXT-X-KEY:METHOD=AES-128,URI=\"http://[broken\"
    # Just a comment
    """

    let result = HLSPlaylistParser.parse(playlist, playlistURL: playlistURL)

    #expect(result.keys.isEmpty)
    #expect(result.segments.count == 1)
    #expect(result.segments[0].remoteURL.absoluteString == "https://cdn.example.com/root/seg-1.ts")
}

@Test func playlistParser_parsesExtXKey_whenURIAttributeContainsComma() throws {
    let playlistURL = try #require(URL(string: "https://cdn.example.com/r/master.m3u8"))
    let playlist = """
    #EXTM3U
    #EXT-X-KEY:KEYFORMAT=\"identity\",URI=\"keys/key.bin?token=a,b\",METHOD=AES-128
    #EXTINF:4.0,
    chunk.ts
    """

    let result = HLSPlaylistParser.parse(playlist, playlistURL: playlistURL)

    #expect(result.keys.count == 1)
    let key = try #require(result.keys.first)
    #expect(key.method == "AES-128")
    #expect(key.uri == "keys/key.bin?token=a,b")
    #expect(key.remoteURL.absoluteString == "https://cdn.example.com/r/keys/key.bin?token=a,b")
}
