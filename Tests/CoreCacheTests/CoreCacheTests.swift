import Foundation
import Testing
@testable import CoreCache

private enum CoreCacheTestError: Error {
    case invalidPlanPartCount(Int)
    case invalidPlanCoverage
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

private func makeCoreCacheTempDirectory(prefix: String = "core-cache-tests") throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(prefix)
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeCoreCacheResourceID(assetID: String = "asset-corecache", suffix: String = "playlist.m3u8") throws -> ResourceID {
    let cacheKey = CacheKey.fromAssetID(assetID)
    let url = try #require(URL(string: "https://cdn.example.com/\(suffix)"))
    return ResourceID(cacheKey: cacheKey, kind: .segment, resourceKey: ResourceID.makeResourceKey(from: url))
}

private func br(_ start: Int64, _ endExclusive: Int64) throws -> ByteRange {
    try #require(ByteRange(start: start, endExclusive: endExclusive))
}

@Test func coreCache_plan_returnsFileAndNetworkPartsForPartialCoverage() throws {
    let directory = try makeCoreCacheTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let cache = try CoreCache(baseDirectory: directory)
    let resource = try makeCoreCacheResourceID()

    _ = try cache.write(Data("AAAA".utf8), resource: resource, at: 0)
    _ = try cache.write(Data("BBBB".utf8), resource: resource, at: 8)

    let plan = try cache.plan(resource: resource, requested: try br(0, 12))
    #expect(plan == [
        .file(try br(0, 4)),
        .network(try br(4, 8)),
        .file(try br(8, 12))
    ])
}

@Test func coreCache_write_updatesCompletedRangesIncrementally() throws {
    let directory = try makeCoreCacheTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let cache = try CoreCache(baseDirectory: directory)
    let resource = try makeCoreCacheResourceID(suffix: "incremental.ts")

    _ = try cache.write(Data("abcd".utf8), resource: resource, at: 0)
    _ = try cache.write(Data("efgh".utf8), resource: resource, at: 4)
    _ = try cache.write(Data("zz".utf8), resource: resource, at: 10)

    let record = try #require(try cache.resourceRecord(for: resource))
    #expect(record.completedRanges.contains(try br(0, 8)))
    #expect(record.completedRanges.contains(try br(10, 12)))
    #expect(!record.completedRanges.contains(try br(8, 10)))
}

@Test func coreCache_write_rejectsCompletedRangeBeyondExpectedLength() throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-expected-length-write")
    defer { try? FileManager.default.removeItem(at: directory) }

    let cache = try CoreCache(baseDirectory: directory)
    let resource = try makeCoreCacheResourceID(suffix: "expected-length-write.ts")

    do {
        _ = try cache.write(
            Data(repeating: 0xAB, count: 8),
            resource: resource,
            at: 0,
            expectedLength: 4
        )
        #expect(Bool(false))
    } catch let error as ResourceRecordInvariantError {
        #expect(error == .completedRangeExceedsExpectedLength(expectedLength: 4, actualEndExclusive: 8))
    } catch {
        #expect(Bool(false))
    }

    #expect(try cache.resourceRecord(for: resource) == nil)
}

@Test func coreCache_finalizeWrite_rejectsExpectedLengthBelowCompletedRanges() throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-expected-length-finalize")
    defer { try? FileManager.default.removeItem(at: directory) }

    let cache = try CoreCache(baseDirectory: directory)
    let resource = try makeCoreCacheResourceID(suffix: "expected-length-finalize.ts")

    _ = try cache.write(Data(repeating: 0xCD, count: 8), resource: resource, at: 0)

    do {
        _ = try cache.finalizeWrite(resource: resource, expectedLength: 4)
        #expect(Bool(false))
    } catch let error as ResourceRecordInvariantError {
        #expect(error == .completedRangeExceedsExpectedLength(expectedLength: 4, actualEndExclusive: 8))
    } catch {
        #expect(Bool(false))
    }

    let record = try #require(try cache.resourceRecord(for: resource))
    #expect(record.expectedLength == nil)
    #expect(record.completedRanges.contains(try br(0, 8)))
}

@Test func coreCache_read_returnsRequestedBytesFromDisk() throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-read")
    defer { try? FileManager.default.removeItem(at: directory) }

    let cache = try CoreCache(baseDirectory: directory)
    let resource = try makeCoreCacheResourceID(suffix: "read.ts")

    _ = try cache.write(Data("0123456789".utf8), resource: resource, at: 0)
    let payload = try cache.read(resource: resource, range: try br(2, 7))
    #expect(String(decoding: payload, as: UTF8.self) == "23456")
}

@Test func coreCache_metrics_tracksHitRatioDiskUsageAndPerAssetCompletion() throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-metrics")
    defer { try? FileManager.default.removeItem(at: directory) }

    let cache = try CoreCache(baseDirectory: directory)

    let assetAFirst = try makeCoreCacheResourceID(assetID: "asset-metrics-a", suffix: "metrics-a-1.ts")
    let assetASecond = try makeCoreCacheResourceID(assetID: "asset-metrics-a", suffix: "metrics-a-2.ts")
    let assetBFirst = try makeCoreCacheResourceID(assetID: "asset-metrics-b", suffix: "metrics-b-1.ts")
    let missing = try makeCoreCacheResourceID(assetID: "asset-metrics-missing", suffix: "metrics-missing.ts")

    _ = try cache.write(Data(repeating: 1, count: 8), resource: assetAFirst, at: 0, expectedLength: 16)
    _ = try cache.finalizeWrite(resource: assetAFirst, expectedLength: 16)
    _ = try cache.write(Data(repeating: 2, count: 4), resource: assetASecond, at: 0, expectedLength: 4)
    _ = try cache.finalizeWrite(resource: assetASecond, expectedLength: 4)
    _ = try cache.write(Data(repeating: 3, count: 2), resource: assetBFirst, at: 0, expectedLength: 2)
    _ = try cache.finalizeWrite(resource: assetBFirst, expectedLength: 2)

    _ = try cache.plan(resource: assetAFirst, requested: try br(0, 8))
    _ = try cache.plan(resource: assetAFirst, requested: try br(0, 16))
    _ = try cache.plan(resource: missing, requested: try br(0, 10))
    cache.recordServedBytes(disk: 14, network: 20)

    let metrics = try cache.metrics()

    #expect(metrics.totalRequests == 3)
    #expect(metrics.fullHitRequests == 1)
    #expect(metrics.partialHitRequests == 1)
    #expect(metrics.missRequests == 1)
    #expect(metrics.requestedBytes == 34)
    #expect(metrics.bytesServedFromDisk == 14)
    #expect(metrics.bytesServedFromNetwork == 20)
    #expect(metrics.bytesPlannedFromCache == 16)
    #expect(metrics.bytesPlannedFromNetwork == 18)
    #expect(abs(metrics.hitRatio - (14.0 / 34.0)) < 0.000_000_1)
    #expect(abs(metrics.diskServeRatio - (14.0 / 34.0)) < 0.000_000_1)
    #expect(abs(metrics.networkServeRatio - (20.0 / 34.0)) < 0.000_000_1)
    #expect(metrics.totalBytesOnDisk == 14)
    #expect(metrics.assets.count == 2)

    let byAsset = Dictionary(uniqueKeysWithValues: metrics.assets.map { ($0.cacheKey, $0) })
    let assetAMetric = try #require(byAsset[CacheKey.fromAssetID("asset-metrics-a")])
    #expect(assetAMetric.resourceCount == 2)
    #expect(assetAMetric.completedBytes == 12)
    #expect(assetAMetric.expectedBytes == 20)
    #expect(abs(assetAMetric.completionRatio - 0.6) < 0.000_000_1)

    let assetBMetric = try #require(byAsset[CacheKey.fromAssetID("asset-metrics-b")])
    #expect(assetBMetric.resourceCount == 1)
    #expect(assetBMetric.completedBytes == 2)
    #expect(assetBMetric.expectedBytes == 2)
    #expect(assetBMetric.completionRatio == 1.0)
}

@Test func coreCache_quotaEviction_evictsLeastRecentlyUpdatedAsset() throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-quota")
    defer { try? FileManager.default.removeItem(at: directory) }

    let logger = RecordingStructuredLogger()
    let cache = try CoreCache(baseDirectory: directory, diskQuotaBytes: 10, logger: logger)
    let first = try makeCoreCacheResourceID(assetID: "asset-first", suffix: "lru-first.ts")
    let second = try makeCoreCacheResourceID(assetID: "asset-second", suffix: "lru-second.ts")

    _ = try cache.write(Data(repeating: 1, count: 6), resource: first, at: 0, expectedLength: 6)
    _ = try cache.finalizeWrite(resource: first, expectedLength: 6)

    Thread.sleep(forTimeInterval: 1.1)

    _ = try cache.write(Data(repeating: 2, count: 6), resource: second, at: 0, expectedLength: 6)
    _ = try cache.finalizeWrite(resource: second, expectedLength: 6)

    #expect(try cache.resourceRecord(for: first) == nil)
    #expect(try cache.resourceRecord(for: second) != nil)
    #expect(try cache.plan(resource: first, requested: try br(0, 6)) == [.network(try br(0, 6))])
    let events = logger.events()
    let evictEvent = try #require(events.first { $0.operation == "evict" })
    #expect(evictEvent.level == .warning)
    #expect(!evictEvent.correlationID.isEmpty)
    #expect(events.contains {
        $0.operation == "write"
            && $0.metadata["cacheKey"] == second.cacheKey.rawValue
            && $0.correlationID == evictEvent.correlationID
    })
}

@Test func coreCache_quotaEviction_evictsWholeAssetGroupNotSingleResource() throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-quota-asset-group")
    defer { try? FileManager.default.removeItem(at: directory) }

    let cache = try CoreCache(baseDirectory: directory, diskQuotaBytes: 10)
    let oldAssetFirst = try makeCoreCacheResourceID(assetID: "asset-old", suffix: "old-1.ts")
    let oldAssetSecond = try makeCoreCacheResourceID(assetID: "asset-old", suffix: "old-2.ts")
    let freshAsset = try makeCoreCacheResourceID(assetID: "asset-fresh", suffix: "fresh-1.ts")

    _ = try cache.write(Data(repeating: 1, count: 4), resource: oldAssetFirst, at: 0, expectedLength: 4)
    _ = try cache.finalizeWrite(resource: oldAssetFirst, expectedLength: 4)
    _ = try cache.write(Data(repeating: 2, count: 4), resource: oldAssetSecond, at: 0, expectedLength: 4)
    _ = try cache.finalizeWrite(resource: oldAssetSecond, expectedLength: 4)

    Thread.sleep(forTimeInterval: 1.1)

    _ = try cache.write(Data(repeating: 3, count: 6), resource: freshAsset, at: 0, expectedLength: 6)
    _ = try cache.finalizeWrite(resource: freshAsset, expectedLength: 6)

    #expect(try cache.resourceRecord(for: oldAssetFirst) == nil)
    #expect(try cache.resourceRecord(for: oldAssetSecond) == nil)
    #expect(try cache.resourceRecord(for: freshAsset) != nil)
}

@Test func coreCache_withoutQuota_doesNotEvictResources() throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-no-quota")
    defer { try? FileManager.default.removeItem(at: directory) }

    let cache = try CoreCache(baseDirectory: directory)
    let first = try makeCoreCacheResourceID(suffix: "keep-first.ts")
    let second = try makeCoreCacheResourceID(suffix: "keep-second.ts")

    _ = try cache.write(Data(repeating: 1, count: 6), resource: first, at: 0, expectedLength: 6)
    _ = try cache.finalizeWrite(resource: first, expectedLength: 6)
    _ = try cache.write(Data(repeating: 2, count: 6), resource: second, at: 0, expectedLength: 6)
    _ = try cache.finalizeWrite(resource: second, expectedLength: 6)

    #expect(try cache.resourceRecord(for: first) != nil)
    #expect(try cache.resourceRecord(for: second) != nil)
}

@Test func coreCache_structuredLogging_emitsWritePlanAndFinalizeEvents() throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-logging")
    defer { try? FileManager.default.removeItem(at: directory) }

    let logger = RecordingStructuredLogger()
    let cache = try CoreCache(baseDirectory: directory, logger: logger)
    let resource = try makeCoreCacheResourceID(suffix: "logging.ts")

    _ = try cache.write(Data(repeating: 7, count: 4), resource: resource, at: 0, expectedLength: 4)
    _ = try cache.finalizeWrite(resource: resource, expectedLength: 4)
    _ = try cache.plan(resource: resource, requested: try br(0, 4))

    let events = logger.events()
    #expect(events.allSatisfy { !$0.correlationID.isEmpty })

    let writeEvent = try #require(events.first { $0.operation == "write" })
    let finalizeEvent = try #require(events.first { $0.operation == "finalizeWrite" })
    let planEvent = try #require(events.first { $0.operation == "plan" })

    #expect(writeEvent.level == .info)
    #expect(finalizeEvent.level == .info)
    #expect(planEvent.level == .debug)
}

@Test func coreCache_finalizeWrite_persistsManifestCrashSafelyAcrossInstances() throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-finalize")
    defer { try? FileManager.default.removeItem(at: directory) }

    let resource = try makeCoreCacheResourceID(suffix: "persisted.ts")
    let stamp = PluginStamp(id: "encrypt-at-rest", version: "1.0.0")

    do {
        let first = try CoreCache(baseDirectory: directory)
        _ = try first.write(
            Data("01234567".utf8),
            resource: resource,
            at: 0,
            contentType: "video/mp2t",
            pluginsApplied: [stamp]
        )
        let finalized = try first.finalizeWrite(resource: resource, expectedLength: 20, pluginsApplied: [stamp])

        #expect(finalized.expectedLength == 20)
        #expect(finalized.completedRanges.contains(try br(0, 8)))
        #expect(finalized.pluginsApplied == [stamp])
    }

    let second = try CoreCache(baseDirectory: directory)
    let restored = try #require(try second.resourceRecord(for: resource))

    #expect(restored.expectedLength == 20)
    #expect(restored.contentType == "video/mp2t")
    #expect(restored.completedRanges.contains(try br(0, 8)))
    #expect(restored.pluginsApplied == [stamp])
}

@Test func coreCache_recovery_corruptedManifest_isTreatedAsCacheMissAndRebuilt() throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-recovery-corrupt-manifest")
    defer { try? FileManager.default.removeItem(at: directory) }

    let resource = try makeCoreCacheResourceID(suffix: "recover-corrupt.ts")
    let initialPayload = Data("initial-segment".utf8)
    let logger = RecordingStructuredLogger()

    do {
        let cache = try CoreCache(baseDirectory: directory)
        _ = try cache.write(initialPayload, resource: resource, at: 0, expectedLength: Int64(initialPayload.count))
        _ = try cache.finalizeWrite(resource: resource, expectedLength: Int64(initialPayload.count))
    }

    let manifestStore = ManifestStore(baseDirectory: directory)
    let manifestURL = manifestStore.manifestFileURL(for: resource)
    let corruptPayload = Data("{\"broken\":".utf8)
    try corruptPayload.write(to: manifestURL)

    let restarted = try CoreCache(baseDirectory: directory, logger: logger)
    let quarantineURL = manifestURL.appendingPathExtension("corrupt")
    let diskStore = DiskStore(baseDirectory: directory)

    #expect(FileManager.default.fileExists(atPath: quarantineURL.path))
    #expect(try Data(contentsOf: quarantineURL) == corruptPayload)
    #expect(!FileManager.default.fileExists(atPath: manifestURL.path))
    #expect(try diskStore.fileLength(for: resource) == 0)
    #expect(try restarted.metrics().totalBytesOnDisk == 0)

    let recoveryEvent = try #require(logger.events().first {
        $0.operation == "manifestDecodeRecovery" && $0.metadata["result"] == "recovered_decode_failure"
    })
    #expect(recoveryEvent.level == .warning)
    #expect(recoveryEvent.metadata["source"] == "allManifestResourceIDs")
    #expect(recoveryEvent.metadata["cacheKey"] == resource.cacheKey.rawValue)
    #expect(recoveryEvent.metadata["kind"] == resource.kind.rawValue)
    let loggedQuarantinePath = try #require(recoveryEvent.metadata["quarantinePath"])
    #expect(
        URL(fileURLWithPath: loggedQuarantinePath).resolvingSymlinksInPath().path
            == quarantineURL.resolvingSymlinksInPath().path
    )
    #expect(recoveryEvent.metadata["recoveryAction"] == "quarantine_manifest_and_purge_data")
    #expect(recoveryEvent.metadata["purgedDataBytes"] == String(initialPayload.count))

    #expect(
        try restarted.plan(resource: resource, requested: try br(0, Int64(initialPayload.count)))
            == [.network(try br(0, Int64(initialPayload.count)))]
    )

    let recoveredPayload = Data("recovered-segment".utf8)
    _ = try restarted.write(
        recoveredPayload,
        resource: resource,
        at: 0,
        expectedLength: Int64(recoveredPayload.count)
    )
    _ = try restarted.finalizeWrite(resource: resource, expectedLength: Int64(recoveredPayload.count))

    let restoredRecord = try #require(try restarted.resourceRecord(for: resource))
    #expect(restoredRecord.completedRanges.contains(try br(0, Int64(recoveredPayload.count))))
    let readBack = try restarted.read(resource: resource, range: try br(0, Int64(recoveredPayload.count)))
    #expect(readBack == recoveredPayload)
}

@Test func coreCache_runtimeLoad_corruptedManifest_quarantinesAndPurgesPairedData() throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-runtime-corrupt-manifest")
    defer { try? FileManager.default.removeItem(at: directory) }

    let logger = RecordingStructuredLogger()
    let cache = try CoreCache(baseDirectory: directory, logger: logger)
    let resource = try makeCoreCacheResourceID(suffix: "runtime-corrupt.ts")
    let payload = Data("runtime-segment".utf8)

    _ = try cache.write(payload, resource: resource, at: 0, expectedLength: Int64(payload.count))
    _ = try cache.finalizeWrite(resource: resource, expectedLength: Int64(payload.count))

    let manifestStore = ManifestStore(baseDirectory: directory)
    let manifestURL = manifestStore.manifestFileURL(for: resource)
    let corruptPayload = Data("{\"runtime\":".utf8)
    try corruptPayload.write(to: manifestURL)

    #expect(
        try cache.plan(resource: resource, requested: try br(0, Int64(payload.count)))
            == [.network(try br(0, Int64(payload.count)))]
    )

    let quarantineURL = manifestURL.appendingPathExtension("corrupt")
    let diskStore = DiskStore(baseDirectory: directory)
    #expect(FileManager.default.fileExists(atPath: quarantineURL.path))
    #expect(try Data(contentsOf: quarantineURL) == corruptPayload)
    #expect(try diskStore.fileLength(for: resource) == 0)

    let recoveryEvent = try #require(logger.events().last {
        $0.operation == "manifestDecodeRecovery" && $0.metadata["result"] == "recovered_decode_failure"
    })
    #expect(recoveryEvent.metadata["source"] == "load")
    #expect(recoveryEvent.metadata["cacheKey"] == resource.cacheKey.rawValue)
    #expect(recoveryEvent.metadata["purgedDataBytes"] == String(payload.count))
}

@Test func coreCache_recovery_orphanManifestTempFile_isClearedOnNextSave() throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-recovery-temp-manifest")
    defer { try? FileManager.default.removeItem(at: directory) }

    let resource = try makeCoreCacheResourceID(suffix: "recover-temp.ts")
    let payload = Data("123456".utf8)

    do {
        let cache = try CoreCache(baseDirectory: directory)
        _ = try cache.write(payload, resource: resource, at: 0, expectedLength: Int64(payload.count))
        _ = try cache.finalizeWrite(resource: resource, expectedLength: Int64(payload.count))
    }

    let manifestStore = ManifestStore(baseDirectory: directory)
    let tempManifestURL = manifestStore.manifestFileURL(for: resource).appendingPathExtension("tmp")
    try Data("{\"partial\":".utf8).write(to: tempManifestURL)
    #expect(FileManager.default.fileExists(atPath: tempManifestURL.path))

    let restarted = try CoreCache(baseDirectory: directory)
    _ = try restarted.write(Data("AB".utf8), resource: resource, at: 0, expectedLength: Int64(payload.count))
    _ = try restarted.finalizeWrite(resource: resource, expectedLength: Int64(payload.count))

    #expect(!FileManager.default.fileExists(atPath: tempManifestURL.path))
}

@Test func coreCache_reconciliation_purgesOrphanDataFileAndEmitsDiagnostics() throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-reconcile-orphan-data")
    defer { try? FileManager.default.removeItem(at: directory) }

    let resource = try makeCoreCacheResourceID(assetID: "asset-orphan-data", suffix: "orphan-data.ts")
    let diskStore = DiskStore(baseDirectory: directory)
    _ = try diskStore.write(Data(repeating: 0x7F, count: 11), for: resource, at: 0)
    #expect(try diskStore.fileLength(for: resource) == 11)

    let logger = RecordingStructuredLogger()
    let cache = try CoreCache(baseDirectory: directory, logger: logger)

    #expect(try diskStore.fileLength(for: resource) == 0)
    #expect(try cache.resourceRecord(for: resource) == nil)
    #expect(try cache.metrics().totalBytesOnDisk == 0)

    let events = logger.events()
    let orphanEvent = try #require(events.first {
        $0.operation == "reconcileStartup" && $0.metadata["action"] == "purgeOrphanData"
    })
    #expect(orphanEvent.level == .warning)
    #expect(orphanEvent.metadata["cacheKey"] == resource.cacheKey.rawValue)

    let summaryEvent = try #require(events.first {
        $0.operation == "reconcileStartup" && $0.metadata["action"] == "summary"
    })
    #expect(summaryEvent.metadata["orphanDataCount"] == "1")
    #expect(summaryEvent.metadata["purgedOrphanDataBytes"] == "11")
}

@Test func coreCache_reconciliation_purgesManifestWithoutDataAndEmitsDiagnostics() throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-reconcile-orphan-manifest")
    defer { try? FileManager.default.removeItem(at: directory) }

    let resource = try makeCoreCacheResourceID(assetID: "asset-orphan-manifest", suffix: "orphan-manifest.ts")
    let manifestStore = ManifestStore(baseDirectory: directory)
    try manifestStore.save(resourceID: resource, record: ResourceRecord(kind: .segment, expectedLength: 9))

    let logger = RecordingStructuredLogger()
    let cache = try CoreCache(baseDirectory: directory, logger: logger)

    #expect(try cache.resourceRecord(for: resource) == nil)
    #expect(try cache.metrics().assets.isEmpty)

    let events = logger.events()
    let orphanManifestEvent = try #require(events.first {
        $0.operation == "reconcileStartup" && $0.metadata["action"] == "purgeOrphanManifest"
    })
    #expect(orphanManifestEvent.level == .warning)
    #expect(orphanManifestEvent.metadata["cacheKey"] == resource.cacheKey.rawValue)

    let summaryEvent = try #require(events.first {
        $0.operation == "reconcileStartup" && $0.metadata["action"] == "summary"
    })
    #expect(summaryEvent.metadata["orphanManifestCount"] == "1")
}

@Test func coreCache_concurrencySmoke_planAndWriteAreThreadSafe() async throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-concurrency")
    defer { try? FileManager.default.removeItem(at: directory) }

    let cache = try CoreCache(baseDirectory: directory)
    let resource = try makeCoreCacheResourceID(suffix: "concurrency.ts")
    let totalLength: Int64 = 32 * 1024

    _ = try cache.write(Data(repeating: 0, count: 512), resource: resource, at: 0, expectedLength: totalLength)

    try await withThrowingTaskGroup(of: Void.self) { group in
        for worker in 0..<6 {
            group.addTask {
                for iteration in 0..<300 {
                    let start = Int64((worker * 97 + iteration * 41) % (Int(totalLength) - 1024))
                    let requested = try br(start, start + 1024)
                    let plan = try cache.plan(resource: resource, requested: requested)
                    if plan.isEmpty {
                        throw CoreCacheTestError.invalidPlanPartCount(plan.count)
                    }
                }
            }
        }

        group.addTask {
            for iteration in 0..<300 {
                let offset = Int64((iteration * 73) % (Int(totalLength) - 256))
                let value = UInt8((iteration % 200) + 1)
                let payload = Data(repeating: value, count: 256)
                _ = try cache.write(payload, resource: resource, at: offset, expectedLength: totalLength)
            }
        }

        try await group.waitForAll()
    }

    let record = try #require(try cache.resourceRecord(for: resource))
    #expect(record.expectedLength == totalLength)
    _ = try cache.finalizeWrite(resource: resource)
}

@Test func coreCache_concurrencySmoke_planWriteFinalize_keepsPlansCoherentAndManifestDecodable() async throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-hardening")
    defer { try? FileManager.default.removeItem(at: directory) }

    let resource = try makeCoreCacheResourceID(suffix: "hardening.ts")
    let totalLength: Int64 = 24 * 1024

    do {
        let cache = try CoreCache(baseDirectory: directory)
        _ = try cache.write(Data(repeating: 0, count: 512), resource: resource, at: 0, expectedLength: totalLength)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<5 {
                group.addTask {
                    for iteration in 0..<250 {
                        let start = Int64((worker * 59 + iteration * 37) % (Int(totalLength) - 512))
                        let requested = try br(start, start + 512)
                        let plan = try cache.plan(resource: resource, requested: requested)
                        try assertPlanCoherent(plan, requested: requested)
                    }
                }
            }

            group.addTask {
                for iteration in 0..<250 {
                    let offset = Int64((iteration * 83) % (Int(totalLength) - 128))
                    let payload = Data(repeating: UInt8((iteration % 190) + 10), count: 128)
                    _ = try cache.write(payload, resource: resource, at: offset, expectedLength: totalLength)
                }
            }

            group.addTask {
                for _ in 0..<80 {
                    _ = try cache.finalizeWrite(resource: resource, expectedLength: totalLength)
                }
            }

            try await group.waitForAll()
        }

        let finalized = try cache.finalizeWrite(resource: resource, expectedLength: totalLength)
        #expect(finalized.expectedLength == totalLength)
    }

    let reloaded = try CoreCache(baseDirectory: directory)
    let restored = try #require(try reloaded.resourceRecord(for: resource))
    #expect(restored.expectedLength == totalLength)

    let normalized = restored.completedRanges.normalized
    for index in 1..<normalized.count {
        #expect(normalized[index - 1].endExclusive < normalized[index].start)
    }
}

@Test func coreCache_concurrencyStress_planMetricsWriteFinalize_remainsConsistent() async throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-metrics-stress")
    defer { try? FileManager.default.removeItem(at: directory) }

    let cache = try CoreCache(baseDirectory: directory)
    let resource = try makeCoreCacheResourceID(suffix: "metrics-stress.ts")
    let totalLength: Int64 = 32 * 1024

    _ = try cache.write(Data(repeating: 0, count: 512), resource: resource, at: 0, expectedLength: totalLength)

    try await withThrowingTaskGroup(of: Void.self) { group in
        for worker in 0..<4 {
            group.addTask {
                for iteration in 0..<240 {
                    let start = Int64((worker * 53 + iteration * 31) % (Int(totalLength) - 256))
                    let requested = try br(start, start + 256)
                    let parts = try cache.plan(resource: resource, requested: requested)
                    try assertPlanCoherent(parts, requested: requested)

                    let servedBytes = parts.reduce(into: (disk: Int64(0), network: Int64(0))) { partial, part in
                        switch part {
                        case let .file(range):
                            partial.disk += range.length
                        case let .network(range):
                            partial.network += range.length
                        }
                    }
                    cache.recordServedBytes(disk: servedBytes.disk, network: servedBytes.network)
                }
            }
        }

        group.addTask {
            for iteration in 0..<260 {
                let offset = Int64((iteration * 83) % (Int(totalLength) - 128))
                let payload = Data(repeating: UInt8((iteration % 220) + 1), count: 128)
                _ = try cache.write(payload, resource: resource, at: offset, expectedLength: totalLength)
            }
        }

        group.addTask {
            for _ in 0..<120 {
                _ = try cache.finalizeWrite(resource: resource, expectedLength: totalLength)
            }
        }

        group.addTask {
            for _ in 0..<320 {
                let snapshot = try cache.metrics()
                #expect(snapshot.totalRequests >= 0)
                #expect(snapshot.fullHitRequests + snapshot.partialHitRequests + snapshot.missRequests == snapshot.totalRequests)
                #expect(snapshot.requestedBytes == snapshot.bytesPlannedFromCache + snapshot.bytesPlannedFromNetwork)
            }
        }

        try await group.waitForAll()
    }

    let record = try #require(try cache.resourceRecord(for: resource))
    #expect(record.expectedLength == totalLength)

    let finalMetrics = try cache.metrics()
    #expect(finalMetrics.fullHitRequests + finalMetrics.partialHitRequests + finalMetrics.missRequests == finalMetrics.totalRequests)
    #expect(finalMetrics.requestedBytes == finalMetrics.bytesPlannedFromCache + finalMetrics.bytesPlannedFromNetwork)
}

@Test func coreCache_directoryLock_contentionFailsFastWithTypedError_andDataRemainsReadableAfterRelease() throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-lock-contention")
    defer { try? FileManager.default.removeItem(at: directory) }

    let resource = try makeCoreCacheResourceID(assetID: "asset-lock", suffix: "lock.ts")
    var first: CoreCache? = try CoreCache(baseDirectory: directory)
    _ = try first?.write(Data("lock-safe".utf8), resource: resource, at: 0, expectedLength: 9)
    _ = try first?.finalizeWrite(resource: resource, expectedLength: 9)

    do {
        _ = try CoreCache(baseDirectory: directory)
        #expect(Bool(false))
    } catch let error as CoreCacheDirectoryLockError {
        switch error {
        case let .directoryInUse(lockFilePath):
            #expect(lockFilePath.hasSuffix(".corecache.lock"))
        case .lockIOFailure:
            #expect(Bool(false))
        }
    }

    first = nil

    let reopened = try CoreCache(baseDirectory: directory)
    let readBack = try reopened.read(resource: resource, range: try br(0, 9))
    #expect(String(decoding: readBack, as: UTF8.self) == "lock-safe")
}

private func assertPlanCoherent(_ parts: [ReadPlanPart], requested: ByteRange) throws {
    var cursor = requested.start
    for part in parts {
        let range: ByteRange
        switch part {
        case let .file(value), let .network(value):
            range = value
        }

        guard range.length > 0 else {
            throw CoreCacheTestError.invalidPlanCoverage
        }
        guard range.start == cursor else {
            throw CoreCacheTestError.invalidPlanCoverage
        }
        guard range.start >= requested.start, range.endExclusive <= requested.endExclusive else {
            throw CoreCacheTestError.invalidPlanCoverage
        }

        cursor = range.endExclusive
    }

    guard cursor == requested.endExclusive else {
        throw CoreCacheTestError.invalidPlanCoverage
    }
}
