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
        exportRunner: { playlistURL, outputURL, videoCodec in
            remuxInvoked = true
            let playlistText = try String(contentsOf: playlistURL, encoding: .utf8)
            #expect(playlistText.contains("segment-00000"))
            #expect(videoCodec == .copy)
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
        exportRunner: { _, _, _ in
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
        exportRunner: { _, _, _ in
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
        exportRunner: { playlistURL, outputURL, videoCodec in
            remuxInvoked = true
            let playlistText = try String(contentsOf: playlistURL, encoding: .utf8)
            #expect(playlistText.contains("key-00000"))
            #expect(playlistText.contains("segment-00000"))
            #expect(videoCodec == .copy)
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

@Test func exporter_exportAV1Mode_invokesTranscodeRunnerAndReturnsOutputSize() throws {
    let directory = try makeExporterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedCachedMediaPlaylist(baseDirectory: directory, alias: "MDEXPORT5", completeCache: true, includeKeyTag: false)

    let facade = HLSCacheFacade(baseDirectory: directory)
    let outputURL = directory.appendingPathComponent("out/video-av1.mp4")
    var exportInvoked = false
    var probeInvoked = false

    let options = AV1TranscodeOptions(preset: "7", crf: 30, bitrate: "1200k")
    let exporter = CLIExporter(
        baseDirectory: directory,
        facade: facade,
        exportRunner: { playlistURL, outputURL, videoCodec in
            exportInvoked = true
            let playlistText = try String(contentsOf: playlistURL, encoding: .utf8)
            #expect(playlistText.contains("segment-00000"))
            #expect(videoCodec == .av1(options))
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("fake-av1-mp4".utf8).write(to: outputURL)
        },
        encoderAvailabilityChecker: { encoderName in
            probeInvoked = true
            #expect(encoderName == "libsvtav1")
        }
    )

    let result = try exporter.export(alias: "MDEXPORT5", outputURL: outputURL, videoCodec: .av1(options))
    #expect(exportInvoked)
    #expect(probeInvoked)
    #expect(result.outputURL == outputURL)
    #expect(result.outputBytes == 12)
}

@Test func exporter_exportAV1Mode_whenEncoderUnavailable_throwsActionableError() throws {
    let directory = try makeExporterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedCachedMediaPlaylist(baseDirectory: directory, alias: "MDEXPORT6", completeCache: true, includeKeyTag: false)

    let facade = HLSCacheFacade(baseDirectory: directory)
    let outputURL = directory.appendingPathComponent("out/video-av1.mp4")
    var exportInvoked = false

    let exporter = CLIExporter(
        baseDirectory: directory,
        facade: facade,
        exportRunner: { _, _, _ in
            exportInvoked = true
            throw CLIExportError.remuxFailed("export should not run when AV1 encoder is unavailable")
        },
        encoderAvailabilityChecker: { _ in
            throw CLIExportError.ffmpegUnavailable("ffmpeg encoder 'libsvtav1' is not available. Install ffmpeg with libsvtav1 support, or rerun export without --av1.")
        }
    )

    do {
        _ = try exporter.export(
            alias: "MDEXPORT6",
            outputURL: outputURL,
            videoCodec: .av1(AV1TranscodeOptions(preset: "6", crf: 32, bitrate: nil))
        )
        #expect(Bool(false))
    } catch let error as CLIExportError {
        #expect(!exportInvoked)
        switch error {
        case let .ffmpegUnavailable(reason):
            #expect(reason.contains("libsvtav1"))
        default:
            #expect(Bool(false))
        }
    }
}

@Test func exporter_exportCompleteCache_reportsProgressEvents() throws {
    let directory = try makeExporterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedCachedMediaPlaylist(baseDirectory: directory, alias: "MDEXPORT7", completeCache: true, includeKeyTag: false)

    let facade = HLSCacheFacade(baseDirectory: directory)
    let outputURL = directory.appendingPathComponent("out/video.mp4")
    var progressEvents: [CLIExportProgress] = []

    let exporter = CLIExporter(
        baseDirectory: directory,
        facade: facade,
        exportRunner: { _, outputURL, _ in
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("fake-mp4".utf8).write(to: outputURL)
        }
    )

    _ = try exporter.export(
        alias: "MDEXPORT7",
        outputURL: outputURL,
        progressHandler: { progress in
            progressEvents.append(progress)
        }
    )

    #expect(!progressEvents.isEmpty)
    #expect(progressEvents.contains { $0.phase == .preparing })
    #expect(progressEvents.contains { $0.phase == .encoding })
    #expect(progressEvents.last?.phase == .completed)
    #expect(progressEvents.last?.processedUnits == progressEvents.last?.totalUnits)
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
@Test func exporter_progressEvents_emitStartedRunningCompleted() async throws {
    let directory = try makeExporterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedCachedMediaPlaylist(baseDirectory: directory, alias: "MDEXPORT8", completeCache: true, includeKeyTag: false)

    let facade = HLSCacheFacade(baseDirectory: directory)
    let outputURL = directory.appendingPathComponent("out/video.mp4")
    let exporter = CLIExporter(
        baseDirectory: directory,
        facade: facade,
        exportRunner: { _, outputURL, _ in
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("fake-mp4".utf8).write(to: outputURL)
        }
    )

    var events: [ProgressEvent] = []
    for try await event in exporter.exportProgressEvents(alias: "MDEXPORT8", outputURL: outputURL) {
        events.append(event)
    }

    #expect(!events.isEmpty)
    #expect(events.first?.state == .started)
    #expect(events.contains { $0.state == .running })
    #expect(events.last?.state == .completed)
    #expect(events.last?.operation == .export)
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
@Test func exporter_legacyWrapper_delegatesToAsyncCore() async throws {
    final class WrapperState: @unchecked Sendable {
        private let lock = NSLock()
        private var progressCount = 0

        func markProgress() {
            lock.lock()
            progressCount += 1
            lock.unlock()
        }

        func snapshotProgressCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return progressCount
        }
    }

    let directory = try makeExporterTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedCachedMediaPlaylist(baseDirectory: directory, alias: "MDEXPORT9", completeCache: true, includeKeyTag: false)

    let facade = HLSCacheFacade(baseDirectory: directory)
    let outputURL = directory.appendingPathComponent("out/video.mp4")
    let exporter = CLIExporter(
        baseDirectory: directory,
        facade: facade,
        exportRunner: { _, outputURL, _ in
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("fake-mp4".utf8).write(to: outputURL)
        }
    )

    let state = WrapperState()
    let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLIExportResult, Error>) in
        _ = exporter.exportLegacy(
            alias: "MDEXPORT9",
            outputURL: outputURL,
            progressHandler: { _ in state.markProgress() },
            completion: { completion in
                continuation.resume(with: completion)
            }
        )
    }

    #expect(state.snapshotProgressCount() > 0)
    #expect(result.outputURL == outputURL)
    #expect(result.outputBytes > 0)
}
