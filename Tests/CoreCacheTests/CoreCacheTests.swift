import Foundation
import Testing
@testable import CoreCache

private enum CoreCacheTestError: Error {
    case invalidPlanPartCount(Int)
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

@Test func coreCache_finalizeWrite_persistsManifestCrashSafelyAcrossInstances() throws {
    let directory = try makeCoreCacheTempDirectory(prefix: "core-cache-finalize")
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = CoreCache(baseDirectory: directory)
    let resource = try makeCoreCacheResourceID(suffix: "persisted.ts")

    _ = try first.write(Data("01234567".utf8), resource: resource, at: 0, contentType: "video/mp2t")
    let finalized = try first.finalizeWrite(resource: resource, expectedLength: 20)

    #expect(finalized.expectedLength == 20)
    #expect(finalized.completedRanges.contains(try br(0, 8)))

    let second = CoreCache(baseDirectory: directory)
    let restored = try #require(try second.resourceRecord(for: resource))

    #expect(restored.expectedLength == 20)
    #expect(restored.contentType == "video/mp2t")
    #expect(restored.completedRanges.contains(try br(0, 8)))
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
