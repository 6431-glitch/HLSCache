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

private final class RecordingStructuredLogger: StructuredLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [StructuredLogEvent] = []

    func log(_ event: StructuredLogEvent) {
        lock.lock()
        storedEvents.append(event)
        lock.unlock()
    }

    func events() -> [StructuredLogEvent] {
        lock.lock()
        let snapshot = storedEvents
        lock.unlock()
        return snapshot
    }
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

@Test func backgroundDownloadTaskRegistry_decodeFailure_quarantinesCorruptFileAndEmitsTelemetry() throws {
    let directory = try makeBackgroundDownloadTempDirectory(prefix: "bg-registry-decode-failure")
    defer { try? FileManager.default.removeItem(at: directory) }

    let registryFileURL = directory.appendingPathComponent("background_download_tasks.json")
    let corruptData = Data("{invalid-json".utf8)
    try corruptData.write(to: registryFileURL)

    let logger = RecordingStructuredLogger()
    let registry = BackgroundDownloadTaskRegistry(baseDirectory: directory, logger: logger)

    #expect(registry.allRecords().isEmpty)

    let corruptFileURL = directory.appendingPathComponent("background_download_tasks.json.corrupt")
    #expect(FileManager.default.fileExists(atPath: registryFileURL.path))
    #expect(FileManager.default.fileExists(atPath: corruptFileURL.path))
    #expect(try Data(contentsOf: corruptFileURL) == corruptData)

    let restoredData = try Data(contentsOf: registryFileURL)
    let restoredRecords = try JSONDecoder.withISO8601.decode([Int: BackgroundDownloadTaskRecord].self, from: restoredData)
    #expect(restoredRecords.isEmpty)

    let event = try #require(
        logger.events().first {
            $0.operation == "loadBackgroundDownloadTaskRegistry"
                && $0.metadata["result"] == "recovered_decode_failure"
        }
    )
    #expect(event.level == .warning)
    #expect(event.metadata["registryPath"] == registryFileURL.path)
    #expect(event.metadata["recoveryPath"] == corruptFileURL.path)
    #expect(event.metadata["recoveryAction"] == "quarantine_and_reset")
    #expect(!(event.metadata["error"] ?? "").isEmpty)
}

@Test func backgroundDownloadTaskRegistry_decodeFailure_recoveryStillAllowsFutureWrites() throws {
    let directory = try makeBackgroundDownloadTempDirectory(prefix: "bg-registry-decode-failure-writes")
    defer { try? FileManager.default.removeItem(at: directory) }

    let registryFileURL = directory.appendingPathComponent("background_download_tasks.json")
    try Data("not-json".utf8).write(to: registryFileURL)

    let registry = BackgroundDownloadTaskRegistry(baseDirectory: directory)
    let resourceID = try makeBackgroundDownloadResourceID(assetID: "asset-bg-recovered", suffix: "seg-recovered.ts")
    let remoteURL = try #require(URL(string: "https://origin.example.com/seg-recovered.ts"))

    _ = try registry.upsert(taskIdentifier: 9901, resourceID: resourceID, remoteURL: remoteURL)
    let restored = try #require(registry.record(taskIdentifier: 9901))
    #expect(restored.resourceID == resourceID)
    #expect(restored.remoteURL == remoteURL)
}

@Test func backgroundDownloadTaskRegistry_loadFailure_quarantinesFaultyPathAndEmitsTelemetry() throws {
    let directory = try makeBackgroundDownloadTempDirectory(prefix: "bg-registry-load-failure")
    defer { try? FileManager.default.removeItem(at: directory) }

    let registryFileURL = directory.appendingPathComponent("background_download_tasks.json")
    try FileManager.default.createDirectory(at: registryFileURL, withIntermediateDirectories: true)

    let logger = RecordingStructuredLogger()
    let registry = BackgroundDownloadTaskRegistry(baseDirectory: directory, logger: logger)

    #expect(registry.allRecords().isEmpty)

    let corruptFileURL = directory.appendingPathComponent("background_download_tasks.json.corrupt")
    var isCorruptDirectory = ObjCBool(false)
    #expect(FileManager.default.fileExists(atPath: corruptFileURL.path, isDirectory: &isCorruptDirectory))
    #expect(isCorruptDirectory.boolValue)
    #expect(FileManager.default.fileExists(atPath: registryFileURL.path))

    let restoredData = try Data(contentsOf: registryFileURL)
    let restoredRecords = try JSONDecoder.withISO8601.decode([Int: BackgroundDownloadTaskRecord].self, from: restoredData)
    #expect(restoredRecords.isEmpty)

    let event = try #require(
        logger.events().first {
            $0.operation == "loadBackgroundDownloadTaskRegistry"
                && $0.metadata["result"] == "recovered_load_failure"
        }
    )
    #expect(event.level == .warning)
    #expect(event.metadata["registryPath"] == registryFileURL.path)
    #expect(event.metadata["recoveryPath"] == corruptFileURL.path)
    #expect(event.metadata["recoveryAction"] == "quarantine_and_reset")
    #expect(!(event.metadata["error"] ?? "").isEmpty)
}

@Test func backgroundDownloadRecovery_startupReconciliation_purgesOrphansAndEmitsDiagnostics() throws {
    let directory = try makeBackgroundDownloadTempDirectory(prefix: "bg-recovery-reconcile-orphans")
    defer { try? FileManager.default.removeItem(at: directory) }

    let diskStore = DiskStore(baseDirectory: directory)
    let manifestStore = ManifestStore(baseDirectory: directory)

    let orphanDataResource = try makeBackgroundDownloadResourceID(assetID: "asset-bg-orphan-data", suffix: "seg-orphan-data.ts")
    let orphanManifestResource = try makeBackgroundDownloadResourceID(assetID: "asset-bg-orphan-manifest", suffix: "seg-orphan-manifest.ts")
    let stagingResource = try makeBackgroundDownloadResourceID(assetID: "asset-bg-orphan-staging", suffix: "seg-orphan-staging.ts")

    let orphanDataPayload = Data("ORPHAN-DATA".utf8)
    _ = try diskStore.write(orphanDataPayload, for: orphanDataResource, at: 0)

    var orphanManifestRecord = ResourceRecord(kind: orphanManifestResource.kind)
    orphanManifestRecord.originalURL = URL(string: "https://origin.example.com/seg-orphan-manifest.ts")
    orphanManifestRecord.expectedLength = 25
    orphanManifestRecord.touch()
    try manifestStore.save(resourceID: orphanManifestResource, record: orphanManifestRecord)

    let stagingURL = diskStore.dataFileURL(for: stagingResource).appendingPathExtension("downloading")
    try FileManager.default.createDirectory(at: stagingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let orphanStagingPayload = Data("PARTIAL".utf8)
    try orphanStagingPayload.write(to: stagingURL)

    let logger = RecordingStructuredLogger()
    _ = BackgroundDownloadRecoveryCoordinator(baseDirectory: directory, logger: logger)

    #expect(FileManager.default.fileExists(atPath: diskStore.dataFileURL(for: orphanDataResource).path) == false)
    #expect(try manifestStore.load(resourceID: orphanManifestResource) == nil)
    #expect(FileManager.default.fileExists(atPath: stagingURL.path) == false)

    let orphanDataEvent = try #require(
        logger.events().first {
            $0.operation == "reconcileBackgroundStartup"
                && $0.metadata["action"] == "purgeOrphanData"
                && $0.metadata["cacheKey"] == orphanDataResource.cacheKey.rawValue
        }
    )
    #expect(orphanDataEvent.level == .warning)
    #expect(orphanDataEvent.metadata["bytes"] == String(orphanDataPayload.count))

    let orphanManifestEvent = try #require(
        logger.events().first {
            $0.operation == "reconcileBackgroundStartup"
                && $0.metadata["action"] == "purgeOrphanManifest"
                && $0.metadata["cacheKey"] == orphanManifestResource.cacheKey.rawValue
        }
    )
    #expect(orphanManifestEvent.level == .warning)

    let orphanStagingEvent = try #require(
        logger.events().first {
            $0.operation == "reconcileBackgroundStartup"
                && $0.metadata["action"] == "purgeOrphanDownloadStaging"
                && $0.metadata["bytes"] == String(orphanStagingPayload.count)
        }
    )
    #expect(orphanStagingEvent.level == .warning)
    #expect((orphanStagingEvent.metadata["path"] ?? "").hasSuffix(".downloading"))
    #expect(orphanStagingEvent.metadata["bytes"] == String(orphanStagingPayload.count))

    let summaryEvent = try #require(
        logger.events().first {
            $0.operation == "reconcileBackgroundStartup" && $0.metadata["action"] == "summary"
        }
    )
    #expect(summaryEvent.metadata["orphanManifestCount"] == "1")
    #expect(summaryEvent.metadata["orphanDataCount"] == "1")
    #expect(summaryEvent.metadata["orphanDownloadStagingCount"] == "1")
}

@Test func backgroundDownloadRecovery_startupReconciliation_keepsMatchedStateUnchanged() throws {
    let directory = try makeBackgroundDownloadTempDirectory(prefix: "bg-recovery-reconcile-matched")
    defer { try? FileManager.default.removeItem(at: directory) }

    let diskStore = DiskStore(baseDirectory: directory)
    let manifestStore = ManifestStore(baseDirectory: directory)
    let resourceID = try makeBackgroundDownloadResourceID(assetID: "asset-bg-reconcile-keep", suffix: "seg-reconcile-keep.ts")

    let payload = Data("MATCHED-DATA".utf8)
    let writtenRange = try diskStore.write(payload, for: resourceID, at: 0)

    var record = ResourceRecord(kind: resourceID.kind)
    record.originalURL = URL(string: "https://origin.example.com/seg-reconcile-keep.ts")
    record.expectedLength = Int64(payload.count)
    record.completedRanges.insert(writtenRange)
    record.touch()
    try manifestStore.save(resourceID: resourceID, record: record)

    let logger = RecordingStructuredLogger()
    _ = BackgroundDownloadRecoveryCoordinator(baseDirectory: directory, logger: logger)

    #expect(FileManager.default.fileExists(atPath: diskStore.dataFileURL(for: resourceID).path))
    let restored = try #require(try manifestStore.load(resourceID: resourceID))
    #expect(restored.expectedLength == Int64(payload.count))
    #expect(restored.completedRanges.contains(writtenRange))

    let summaryEvent = try #require(
        logger.events().first {
            $0.operation == "reconcileBackgroundStartup" && $0.metadata["action"] == "summary"
        }
    )
    #expect(summaryEvent.metadata["orphanManifestCount"] == "0")
    #expect(summaryEvent.metadata["orphanDataCount"] == "0")
    #expect(summaryEvent.metadata["orphanDownloadStagingCount"] == "0")
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

@Test func backgroundURLSessionCoordinator_registerAndRecoverPendingTasks_fromURLSessionTasks() throws {
    let directory = try makeBackgroundDownloadTempDirectory(prefix: "bg-urlsession-recover")
    defer { try? FileManager.default.removeItem(at: directory) }

    let coordinator = BackgroundURLSessionDownloadCoordinator(baseDirectory: directory)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }

    let remoteURL1 = try #require(URL(string: "https://origin.example.com/seg-401.ts"))
    let remoteURL2 = try #require(URL(string: "https://origin.example.com/seg-402.ts"))
    let task1 = session.downloadTask(with: remoteURL1)
    let task2 = session.downloadTask(with: remoteURL2)

    _ = try coordinator.registerDownloadTask(
        task1,
        resourceID: try makeBackgroundDownloadResourceID(assetID: "asset-bg-401", suffix: "seg-401.ts"),
        remoteURL: remoteURL1
    )
    _ = try coordinator.registerDownloadTask(
        task2,
        resourceID: try makeBackgroundDownloadResourceID(assetID: "asset-bg-402", suffix: "seg-402.ts"),
        remoteURL: remoteURL2
    )

    let recovered = try coordinator.recoverPendingTasks(activeTasks: [task2])
    #expect(recovered.count == 1)
    #expect(recovered.first?.taskIdentifier == task2.taskIdentifier)
    #expect(coordinator.taskRecord(for: task1) == nil)
    #expect(coordinator.taskRecord(for: task2) != nil)
}

@Test func backgroundURLSessionCoordinator_completeDownload_usesResponseMetadataAndUpdatesManifest() throws {
    let directory = try makeBackgroundDownloadTempDirectory(prefix: "bg-urlsession-complete")
    defer { try? FileManager.default.removeItem(at: directory) }

    let coordinator = BackgroundURLSessionDownloadCoordinator(baseDirectory: directory)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }

    let remoteURL = try #require(URL(string: "https://origin.example.com/seg-500.ts"))
    let task = session.downloadTask(with: remoteURL)
    let resourceID = try makeBackgroundDownloadResourceID(assetID: "asset-bg-500", suffix: "seg-500.ts")

    _ = try coordinator.registerDownloadTask(
        task,
        resourceID: resourceID,
        remoteURL: remoteURL
    )

    let payload = Data("SEGMENT-DATA".utf8)
    let temporaryFileURL = directory.appendingPathComponent("seg-500.tmp")
    try payload.write(to: temporaryFileURL)
    let response = try #require(
        HTTPURLResponse(
            url: remoteURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "video/mp2t",
                "Content-Length": String(payload.count)
            ]
        )
    )

    let result = try coordinator.completeDownload(
        task: task,
        temporaryFileURL: temporaryFileURL,
        response: response
    )

    #expect(result.taskIdentifier == task.taskIdentifier)
    #expect(coordinator.taskRecord(for: task) == nil)

    let manifestStore = ManifestStore(baseDirectory: directory)
    let manifest = try #require(try manifestStore.load(resourceID: resourceID))
    #expect(manifest.originalURL == remoteURL)
    #expect(manifest.contentType == "video/mp2t")
    #expect(manifest.expectedLength == Int64(payload.count))
}

private extension JSONDecoder {
    static var withISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
