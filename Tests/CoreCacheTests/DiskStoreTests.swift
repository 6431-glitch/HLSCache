import Foundation
import Testing
@testable import CoreCache

private enum DiskStoreTestError: Error {
    case invalidChunkLength(Int)
}

private func makeDiskStoreTempDirectory(prefix: String = "disk-store-tests") throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(prefix)
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeResourceID(suffix: String = "segment.ts") throws -> ResourceID {
    let cacheKey = CacheKey.fromAssetID("asset-disk-store")
    let url = try #require(URL(string: "https://cdn.example.com/video/\(suffix)"))
    let resourceKey = ResourceID.makeResourceKey(from: url)
    return ResourceID(cacheKey: cacheKey, kind: .segment, resourceKey: resourceKey)
}

private func br(_ start: Int64, _ endExclusive: Int64) throws -> ByteRange {
    try #require(ByteRange(start: start, endExclusive: endExclusive))
}

@Test func diskStore_randomAccessRead_readsOnlyRequestedRange() throws {
    let directory = try makeDiskStoreTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = DiskStore(baseDirectory: directory)
    let resourceID = try makeResourceID()
    let payload = Data("0123456789abcdef".utf8)

    _ = try store.write(payload, for: resourceID, at: 0)

    let read = try store.read(resourceID: resourceID, range: try br(2, 6))
    #expect(String(decoding: read, as: UTF8.self) == "2345")
}

@Test func diskStore_seekWrite_overwritesAtOffsetWithoutRebufferingWholeFile() throws {
    let directory = try makeDiskStoreTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = DiskStore(baseDirectory: directory)
    let resourceID = try makeResourceID(suffix: "seek-overwrite.ts")

    _ = try store.write(Data("0123456789".utf8), for: resourceID, at: 0)
    _ = try store.write(Data("ABCD".utf8), for: resourceID, at: 3)

    let read = try store.read(resourceID: resourceID, range: try br(0, 10))
    #expect(String(decoding: read, as: UTF8.self) == "012ABCD789")
}

@Test func diskStore_write_autoCreatesNestedDirectoriesAndDataFile() throws {
    let directory = try makeDiskStoreTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = DiskStore(baseDirectory: directory)
    let resourceID = try makeResourceID(suffix: "nested/creation.ts")
    let fileURL = store.dataFileURL(for: resourceID)

    #expect(!FileManager.default.fileExists(atPath: fileURL.path))

    _ = try store.write(Data([0x01, 0x02, 0x03]), for: resourceID, at: 0)

    #expect(FileManager.default.fileExists(atPath: fileURL.path))
    #expect(FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path))
}

@Test func diskStore_read_clampsToEOFAndReturnsEmptyWhenRangeStartsPastEOF() throws {
    let directory = try makeDiskStoreTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = DiskStore(baseDirectory: directory)
    let resourceID = try makeResourceID(suffix: "eof.ts")

    _ = try store.write(Data("12345".utf8), for: resourceID, at: 0)

    let clamped = try store.read(resourceID: resourceID, range: try br(3, 10))
    #expect(String(decoding: clamped, as: UTF8.self) == "45")

    let pastEOF = try store.read(resourceID: resourceID, range: try br(10, 20))
    #expect(pastEOF.isEmpty)
}

@Test func diskStore_concurrencySmoke_readAndWriteConcurrently_remainsConsistent() async throws {
    let directory = try makeDiskStoreTempDirectory(prefix: "disk-store-concurrency")
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = DiskStore(baseDirectory: directory)
    let resourceID = try makeResourceID(suffix: "concurrency.ts")
    let initialLength = 16 * 1024

    _ = try store.write(Data(repeating: 0, count: initialLength), for: resourceID, at: 0)

    try await withThrowingTaskGroup(of: Void.self) { group in
        for readerID in 0..<6 {
            group.addTask {
                for iteration in 0..<400 {
                    let start = Int64((readerID * 211 + iteration * 97) % (initialLength - 256))
                    let endExclusive = start + 256
                    let chunk = try store.read(resourceID: resourceID, range: try br(start, endExclusive))
                    if chunk.count > 256 {
                        throw DiskStoreTestError.invalidChunkLength(chunk.count)
                    }
                }
            }
        }

        group.addTask {
            for iteration in 0..<400 {
                let offset = Int64((iteration * 131) % (initialLength - 128))
                let value = UInt8((iteration % 200) + 1)
                let data = Data(repeating: value, count: 128)
                _ = try store.write(data, for: resourceID, at: offset)
            }
        }

        try await group.waitForAll()
    }

    #expect(try store.fileLength(for: resourceID) == Int64(initialLength))
}
