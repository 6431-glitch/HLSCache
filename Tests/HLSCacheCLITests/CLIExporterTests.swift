import CoreCache
import Foundation
import HLSCache
import Testing
@testable import HLSCacheCLI

private func makeExporterTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-cli-export-tests")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeCompletedRanges(_ length: Int64) -> IntervalSet {
    var set = IntervalSet()
    if let range = ByteRange(start: 0, endExclusive: length) {
        set.insert(range)
    }
    return set
}

private func seedCachedMediaPlaylist(
    baseDirectory: URL,
    alias: String,
    completeCache: Bool,
    includeKeyTag: Bool,
    includeKeyData: Bool = false
) throws {
    let facade = HLSCacheFacade(baseDirectory: baseDirectory)
    let playlistURL = try #require(URL(string: "https://cdn.example.com/video/media.m3u8"))
    let registered = try facade.register(
        alias: alias,
        assetID: "asset-\(alias.lowercased())",
        remoteURL: playlistURL
    )

    let segment1URL = try #require(URL(string: "https://cdn.example.com/video/seg-1.ts"))
    let segment2URL = try #require(URL(string: "https://cdn.example.com/video/seg-2.ts"))
    let keyURL = try #require(URL(string: "https://cdn.example.com/video/enc.key"))

    var playlistLines = [
        "#EXTM3U",
        "#EXT-X-VERSION:3",
        "#EXT-X-TARGETDURATION:8",
        "#EXTINF:8.0,",
        "seg-1.ts",
        "#EXTINF:8.0,",
        "seg-2.ts",
        "#EXT-X-ENDLIST"
    ]
    if includeKeyTag {
        playlistLines.insert("#EXT-X-KEY:METHOD=AES-128,URI=\"enc.key\"", at: 3)
    }
    let playlistBody = playlistLines.joined(separator: "\n")

    let manifestStore = ManifestStore(baseDirectory: baseDirectory)
    let diskStore = DiskStore(baseDirectory: baseDirectory)

    let playlistResourceID = ResourceID(
        cacheKey: registered.cacheKey,
        kind: .playlistM3U8,
        resourceKey: ResourceID.makeResourceKey(from: playlistURL)
    )
    let playlistData = Data(playlistBody.utf8)
    _ = try diskStore.write(playlistData, for: playlistResourceID, at: 0)
    try manifestStore.save(
        resourceID: playlistResourceID,
        record: ResourceRecord(
            kind: .playlistM3U8,
            originalURL: playlistURL,
            contentType: "application/vnd.apple.mpegurl",
            expectedLength: Int64(playlistData.count),
            completedRanges: makeCompletedRanges(Int64(playlistData.count))
        )
    )

    let segment1Data = Data(repeating: 0x11, count: 188)
    let segment1ResourceID = ResourceID(
        cacheKey: registered.cacheKey,
        kind: .segment,
        resourceKey: ResourceID.makeResourceKey(from: segment1URL)
    )
    _ = try diskStore.write(segment1Data, for: segment1ResourceID, at: 0)
    try manifestStore.save(
        resourceID: segment1ResourceID,
        record: ResourceRecord(
            kind: .segment,
            originalURL: segment1URL,
            contentType: "video/mp2t",
            expectedLength: Int64(segment1Data.count),
            completedRanges: makeCompletedRanges(Int64(segment1Data.count))
        )
    )

    let segment2Data = Data(repeating: 0x22, count: 188)
    let segment2ResourceID = ResourceID(
        cacheKey: registered.cacheKey,
        kind: .segment,
        resourceKey: ResourceID.makeResourceKey(from: segment2URL)
    )
    if completeCache {
        _ = try diskStore.write(segment2Data, for: segment2ResourceID, at: 0)
        try manifestStore.save(
            resourceID: segment2ResourceID,
            record: ResourceRecord(
                kind: .segment,
                originalURL: segment2URL,
                contentType: "video/mp2t",
                expectedLength: Int64(segment2Data.count),
                completedRanges: makeCompletedRanges(Int64(segment2Data.count))
            )
        )
    } else {
        let partial = Data(segment2Data.prefix(94))
        _ = try diskStore.write(partial, for: segment2ResourceID, at: 0)
        try manifestStore.save(
            resourceID: segment2ResourceID,
            record: ResourceRecord(
                kind: .segment,
                originalURL: segment2URL,
                contentType: "video/mp2t",
                expectedLength: Int64(segment2Data.count),
                completedRanges: makeCompletedRanges(Int64(partial.count))
            )
        )
    }

    if includeKeyTag, includeKeyData {
        let keyData = Data(repeating: 0xAB, count: 16)
        let keyResourceID = ResourceID(
            cacheKey: registered.cacheKey,
            kind: .key,
            resourceKey: ResourceID.makeResourceKey(from: keyURL)
        )
        _ = try diskStore.write(keyData, for: keyResourceID, at: 0)
        try manifestStore.save(
            resourceID: keyResourceID,
            record: ResourceRecord(
                kind: .key,
                originalURL: keyURL,
                contentType: "application/octet-stream",
                expectedLength: Int64(keyData.count),
                completedRanges: makeCompletedRanges(Int64(keyData.count))
            )
        )
    }
}

@Test func exporter_exportCompleteCache_invokesRemuxAndReturnsOutputSize() throws {
    let directory = try makeExporterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedCachedMediaPlaylist(baseDirectory: directory, alias: "MDEXPORT1", completeCache: true, includeKeyTag: false)

    let facade = HLSCacheFacade(baseDirectory: directory)
    let outputURL = directory.appendingPathComponent("out/video.mp4")
    var remuxInvoked = false

    let exporter = CLIExporter(
        baseDirectory: directory,
        facade: facade,
        remuxRunner: { playlistURL, outputURL in
            remuxInvoked = true
            let playlistText = try String(contentsOf: playlistURL, encoding: .utf8)
            #expect(playlistText.contains("segment-00000"))
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("fake-mp4".utf8).write(to: outputURL)
        }
    )

    let result = try exporter.export(alias: "MDEXPORT1", outputURL: outputURL)
    #expect(remuxInvoked)
    #expect(result.outputURL == outputURL)
    #expect(result.outputBytes == 8)
}

@Test func exporter_exportIncompleteCache_throwsActionableError() throws {
    let directory = try makeExporterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedCachedMediaPlaylist(baseDirectory: directory, alias: "MDEXPORT2", completeCache: false, includeKeyTag: false)

    let facade = HLSCacheFacade(baseDirectory: directory)
    let outputURL = directory.appendingPathComponent("out/video.mp4")
    let exporter = CLIExporter(
        baseDirectory: directory,
        facade: facade,
        remuxRunner: { _, _ in
            throw CLIExportError.remuxFailed("should not be invoked for incomplete cache")
        }
    )

    do {
        _ = try exporter.export(alias: "MDEXPORT2", outputURL: outputURL)
        #expect(Bool(false))
    } catch let error as CLIExportError {
        switch error {
        case let .incompleteCache(reason):
            #expect(reason.contains("missing or incomplete segment"))
        default:
            #expect(Bool(false))
        }
    }
}

@Test func exporter_exportEncryptedPlaylist_throwsActionableError() throws {
    let directory = try makeExporterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedCachedMediaPlaylist(baseDirectory: directory, alias: "MDEXPORT3", completeCache: true, includeKeyTag: true)

    let facade = HLSCacheFacade(baseDirectory: directory)
    let outputURL = directory.appendingPathComponent("out/video.mp4")
    let exporter = CLIExporter(
        baseDirectory: directory,
        facade: facade,
        remuxRunner: { _, _ in
            throw CLIExportError.remuxFailed("should not be invoked for encrypted playlist")
        }
    )

    do {
        _ = try exporter.export(alias: "MDEXPORT3", outputURL: outputURL)
        #expect(Bool(false))
    } catch let error as CLIExportError {
        switch error {
        case let .incompleteCache(reason):
            #expect(reason.contains("missing or incomplete key"))
        default:
            #expect(Bool(false))
        }
    }
}

@Test func exporter_exportEncryptedPlaylistWithCachedKey_invokesRemuxAndReturnsOutputSize() throws {
    let directory = try makeExporterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedCachedMediaPlaylist(
        baseDirectory: directory,
        alias: "MDEXPORT4",
        completeCache: true,
        includeKeyTag: true,
        includeKeyData: true
    )

    let facade = HLSCacheFacade(baseDirectory: directory)
    let outputURL = directory.appendingPathComponent("out/video.mp4")
    var remuxInvoked = false

    let exporter = CLIExporter(
        baseDirectory: directory,
        facade: facade,
        remuxRunner: { playlistURL, outputURL in
            remuxInvoked = true
            let playlistText = try String(contentsOf: playlistURL, encoding: .utf8)
            #expect(playlistText.contains("key-00000"))
            #expect(playlistText.contains("segment-00000"))
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("fake-mp4".utf8).write(to: outputURL)
        }
    )

    let result = try exporter.export(alias: "MDEXPORT4", outputURL: outputURL)
    #expect(remuxInvoked)
    #expect(result.outputURL == outputURL)
    #expect(result.outputBytes == 8)
}
