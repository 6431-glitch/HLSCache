import CoreCache
import Foundation
import Testing
@testable import HLSCache

private func makeBackgroundDownloadTempDirectory(prefix: String = "hlscache-background-download") throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(prefix)
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeBackgroundDownloadResourceID(assetID: String, suffix: String) throws -> ResourceID {
    let cacheKey = CacheKey.fromAssetID(assetID)
    let url = try #require(URL(string: "https://cdn.example.com/\(suffix)"))
    return ResourceID(cacheKey: cacheKey, kind: .segment, resourceKey: ResourceID.makeResourceKey(from: url))
}

@Test func backgroundDownloadTaskRegistry_persistsTaskMappingAcrossInstances() throws {
    let directory = try makeBackgroundDownloadTempDirectory(prefix: "bg-registry-persistence")
    defer { try? FileManager.default.removeItem(at: directory) }

    let registry = BackgroundDownloadTaskRegistry(baseDirectory: directory)
    let resourceID = try makeBackgroundDownloadResourceID(assetID: "asset-bg-100", suffix: "seg-100.ts")
    let remoteURL = try #require(URL(string: "https://origin.example.com/seg-100.ts"))

    let saved = try registry.upsert(
        taskIdentifier: 1001,
        resourceID: resourceID,
        remoteURL: remoteURL,
        contentType: "video/mp2t",
        expectedLength: 1024
    )
    #expect(saved.taskIdentifier == 1001)

    let restoredRegistry = BackgroundDownloadTaskRegistry(baseDirectory: directory)
    let restored = try #require(restoredRegistry.record(taskIdentifier: 1001))
    #expect(restored.resourceID == resourceID)
    #expect(restored.remoteURL == remoteURL)
    #expect(restored.contentType == "video/mp2t")
    #expect(restored.expectedLength == 1024)
}

@Test func backgroundDownloadRecovery_recoverPendingTasks_prunesStaleMappings() throws {
    let directory = try makeBackgroundDownloadTempDirectory(prefix: "bg-recovery-relaunch")
    defer { try? FileManager.default.removeItem(at: directory) }

    let coordinator = BackgroundDownloadRecoveryCoordinator(baseDirectory: directory)
    let firstResource = try makeBackgroundDownloadResourceID(assetID: "asset-bg-200", suffix: "seg-200.ts")
    let secondResource = try makeBackgroundDownloadResourceID(assetID: "asset-bg-201", suffix: "seg-201.ts")

    _ = try coordinator.registerTask(
        taskIdentifier: 2001,
        resourceID: firstResource,
        remoteURL: try #require(URL(string: "https://origin.example.com/seg-200.ts"))
    )
    _ = try coordinator.registerTask(
        taskIdentifier: 2002,
        resourceID: secondResource,
        remoteURL: try #require(URL(string: "https://origin.example.com/seg-201.ts"))
    )

    let recovered = try coordinator.recoverPendingTasks(activeTaskIdentifiers: [2002, 2003])
    #expect(recovered.count == 1)
    #expect(recovered.first?.taskIdentifier == 2002)
    #expect(coordinator.taskRecord(for: 2001) == nil)
    #expect(coordinator.taskRecord(for: 2002) != nil)
}

@Test func backgroundDownloadRecovery_completeDownload_movesFileAndUpdatesManifest() throws {
    let directory = try makeBackgroundDownloadTempDirectory(prefix: "bg-recovery-complete")
    defer { try? FileManager.default.removeItem(at: directory) }

    let coordinator = BackgroundDownloadRecoveryCoordinator(baseDirectory: directory)
    let resourceID = try makeBackgroundDownloadResourceID(assetID: "asset-bg-300", suffix: "seg-300.ts")
    let remoteURL = try #require(URL(string: "https://origin.example.com/seg-300.ts"))

    _ = try coordinator.registerTask(
        taskIdentifier: 3001,
        resourceID: resourceID,
        remoteURL: remoteURL,
        contentType: "video/mp2t",
        expectedLength: 12
    )

    let temporaryFileURL = directory.appendingPathComponent("downloaded-segment.tmp")
    let payload = Data("HELLO-WORLD!".utf8)
    try payload.write(to: temporaryFileURL)

    let result = try coordinator.completeDownload(
        taskIdentifier: 3001,
        temporaryFileURL: temporaryFileURL
    )

    #expect(result.taskIdentifier == 3001)
    #expect(result.resourceID == resourceID)
    #expect(result.bytesWritten == Int64(payload.count))
    #expect(coordinator.taskRecord(for: 3001) == nil)

    let diskStore = DiskStore(baseDirectory: directory)
    let fullRange = try #require(ByteRange(start: 0, endExclusive: Int64(payload.count)))
    let restoredPayload = try diskStore.read(resourceID: resourceID, range: fullRange)
    #expect(restoredPayload == payload)

    let manifestStore = ManifestStore(baseDirectory: directory)
    let manifest = try #require(try manifestStore.load(resourceID: resourceID))
    #expect(manifest.originalURL == remoteURL)
    #expect(manifest.contentType == "video/mp2t")
    #expect(manifest.expectedLength == 12)
    #expect(manifest.completedRanges.contains(fullRange))
}
