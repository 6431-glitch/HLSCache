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

private func makeCoreCacheResourceID(suffix: String = "playlist.m3u8") throws -> ResourceID {
    let cacheKey = CacheKey.fromAssetID("asset-corecache")
    let url = try #require(URL(string: "https://cdn.example.com/\(suffix)"))
    return ResourceID(cacheKey: cacheKey, kind: .segment, resourceKey: ResourceID.makeResourceKey(from: url))
}

private func br(_ start: Int64, _ endExclusive: Int64) throws -> ByteRange {
    try #require(ByteRange(start: start, endExclusive: endExclusive))
}

@Test func coreCache_plan_returnsFileAndNetworkPartsForPartialCoverage() throws {
    let directory = try makeCoreCacheTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let cache = CoreCache(baseDirectory: directory)
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

    let cache = CoreCache(baseDirectory: directory)
    let resource = try makeCoreCacheResourceID(suffix: "incremental.ts")

    _ = try cache.write(Data("abcd".utf8), resource: resource, at: 0)
    _ = try cache.write(Data("efgh".utf8), resource: resource, at: 4)
    _ = try cache.write(Data("zz".utf8), resource: resource, at: 10)

    let record = try #require(try cache.resourceRecord(for: resource))
    #expect(record.completedRanges.contains(try br(0, 8)))
    #expect(record.completedRanges.contains(try br(10, 12)))
    #expect(!record.completedRanges.contains(try br(8, 10)))
}

@Test func coreCache_read_returnsRequestedBytesFromDisk() throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-read")
    defer { try? FileManager.default.removeItem(at: directory) }

    let cache = CoreCache(baseDirectory: directory)
    let resource = try makeCoreCacheResourceID(suffix: "read.ts")

    _ = try cache.write(Data("0123456789".utf8), resource: resource, at: 0)
    let payload = try cache.read(resource: resource, range: try br(2, 7))
    #expect(String(decoding: payload, as: UTF8.self) == "23456")
}

@Test func coreCache_quotaEviction_evictsLeastRecentlyUpdatedResource() throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-quota")
    defer { try? FileManager.default.removeItem(at: directory) }

    let logger = RecordingStructuredLogger()
    let cache = CoreCache(baseDirectory: directory, diskQuotaBytes: 10, logger: logger)
    let first = try makeCoreCacheResourceID(suffix: "lru-first.ts")
    let second = try makeCoreCacheResourceID(suffix: "lru-second.ts")

    _ = try cache.write(Data(repeating: 1, count: 6), resource: first, at: 0, expectedLength: 6)
    _ = try cache.finalizeWrite(resource: first, expectedLength: 6)

    Thread.sleep(forTimeInterval: 0.02)

    _ = try cache.write(Data(repeating: 2, count: 6), resource: second, at: 0, expectedLength: 6)
    _ = try cache.finalizeWrite(resource: second, expectedLength: 6)

    #expect(try cache.resourceRecord(for: first) == nil)
    #expect(try cache.resourceRecord(for: second) != nil)
    #expect(try cache.plan(resource: first, requested: try br(0, 6)) == [.network(try br(0, 6))])
    #expect(logger.events().contains { $0.operation == "evict" })
}

@Test func coreCache_withoutQuota_doesNotEvictResources() throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-no-quota")
    defer { try? FileManager.default.removeItem(at: directory) }

    let cache = CoreCache(baseDirectory: directory)
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
    let cache = CoreCache(baseDirectory: directory, logger: logger)
    let resource = try makeCoreCacheResourceID(suffix: "logging.ts")

    _ = try cache.write(Data(repeating: 7, count: 4), resource: resource, at: 0, expectedLength: 4)
    _ = try cache.finalizeWrite(resource: resource, expectedLength: 4)
    _ = try cache.plan(resource: resource, requested: try br(0, 4))

    let operations = Set(logger.events().map(\.operation))
    #expect(operations.contains("write"))
    #expect(operations.contains("finalizeWrite"))
    #expect(operations.contains("plan"))
}

@Test func coreCache_finalizeWrite_persistsManifestCrashSafelyAcrossInstances() throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-finalize")
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = CoreCache(baseDirectory: directory)
    let resource = try makeCoreCacheResourceID(suffix: "persisted.ts")
    let stamp = PluginStamp(id: "encrypt-at-rest", version: "1.0.0")

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

    let second = CoreCache(baseDirectory: directory)
    let restored = try #require(try second.resourceRecord(for: resource))

    #expect(restored.expectedLength == 20)
    #expect(restored.contentType == "video/mp2t")
    #expect(restored.completedRanges.contains(try br(0, 8)))
    #expect(restored.pluginsApplied == [stamp])
}

@Test func coreCache_concurrencySmoke_planAndWriteAreThreadSafe() async throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-concurrency")
    defer { try? FileManager.default.removeItem(at: directory) }

    let cache = CoreCache(baseDirectory: directory)
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

    let cache = CoreCache(baseDirectory: directory)
    let resource = try makeCoreCacheResourceID(suffix: "hardening.ts")
    let totalLength: Int64 = 24 * 1024

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

    let reloaded = CoreCache(baseDirectory: directory)
    let restored = try #require(try reloaded.resourceRecord(for: resource))
    #expect(restored.expectedLength == totalLength)

    let normalized = restored.completedRanges.normalized
    for index in 1..<normalized.count {
        #expect(normalized[index - 1].endExclusive < normalized[index].start)
    }
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
