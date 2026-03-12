import CoreCache
import Foundation
import Testing
@testable import HLSCache

private func makeCoordinatorResourceID() throws -> ResourceID {
    let cacheKey = CacheKey.fromAssetID("asset-proxy-coordinator")
    let remoteURL = try #require(URL(string: "https://cdn.example.com/video/proxy.mp4"))
    return ResourceID(cacheKey: cacheKey, kind: .other, resourceKey: ResourceID.makeResourceKey(from: remoteURL))
}

@Test func proxyCacheCoordinator_corruptedCachedRange_fetchesMissingTailFromNetwork() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 1024
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 241) })
    let resourceID = try makeCoordinatorResourceID()

    let cache = CoreCache(baseDirectory: directory)
    let coordinator = ProxyCacheCoordinator(coreCache: cache)

    _ = try coordinator.serve(
        resourceID: resourceID,
        rangeHeader: "bytes=0-511",
        totalLength: totalLength,
        fetchNetworkRange: { range in
            Data(originData[Int(range.start)..<Int(range.endExclusive)])
        },
        emit: { _ in }
    )
    let initialRecord = try #require(try cache.resourceRecord(for: resourceID))
    #expect(initialRecord.pluginsApplied.isEmpty)

    let diskStore = DiskStore(baseDirectory: directory)
    let fileURL = diskStore.dataFileURL(for: resourceID)
    let fileHandle = try FileHandle(forWritingTo: fileURL)
    try fileHandle.truncate(atOffset: 300)
    try fileHandle.close()

    var networkFetches = 0
    var payload = Data()
    let result = try coordinator.serve(
        resourceID: resourceID,
        rangeHeader: "bytes=256-511",
        totalLength: totalLength,
        fetchNetworkRange: { range in
            networkFetches += 1
            return Data(originData[Int(range.start)..<Int(range.endExclusive)])
        },
        emit: { payload.append($0) }
    )

    let cachedPrefix = try #require(ByteRange(start: 256, endExclusive: 300))
    let missingTail = try #require(ByteRange(start: 300, endExclusive: 512))
    #expect(result.chunks == [
        ProxyStreamChunk(source: .cache, range: cachedPrefix, byteCount: 44),
        ProxyStreamChunk(source: .network, range: missingTail, byteCount: 212)
    ])
    #expect(networkFetches == 1)
    #expect(payload == Data(originData[256..<512]))
}

@Test func proxyCacheCoordinator_networkChunkLengthMismatch_throws() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-mismatch")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let cache = CoreCache(baseDirectory: directory)
    let coordinator = ProxyCacheCoordinator(coreCache: cache)
    let resourceID = try makeCoordinatorResourceID()

    do {
        _ = try coordinator.serve(
            resourceID: resourceID,
            rangeHeader: "bytes=0-99",
            totalLength: 1000,
            fetchNetworkRange: { _ in Data(repeating: 7, count: 50) },
            emit: { _ in }
        )
        #expect(Bool(false))
    } catch let error as ProxyCacheCoordinatorError {
        #expect(error == .invalidNetworkChunkLength(expected: 100, actual: 50))
    }
}

@Test func proxyCacheCoordinator_encryptAtRest_storesEncryptedAndServesDecrypted() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-encrypt")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 512
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 253) })
    let resourceID = try makeCoordinatorResourceID()

    let cache = CoreCache(baseDirectory: directory)
    let pipeline = TransformPipeline(transformers: [EncryptAtRestPlugin(key: Data("encrypt-key".utf8))])
    let coordinator = ProxyCacheCoordinator(coreCache: cache, transformPipeline: pipeline)

    var firstPayload = Data()
    var firstFetches = 0
    _ = try coordinator.serve(
        resourceID: resourceID,
        rangeHeader: "bytes=0-255",
        totalLength: totalLength,
        fetchNetworkRange: { range in
            firstFetches += 1
            return Data(originData[Int(range.start)..<Int(range.endExclusive)])
        },
        emit: { firstPayload.append($0) }
    )

    #expect(firstFetches == 1)
    #expect(firstPayload == Data(originData[0..<256]))
    let stamp = PluginStamp(id: "encrypt-at-rest", version: "1.0.0")
    let firstRecord = try #require(try cache.resourceRecord(for: resourceID))
    #expect(firstRecord.pluginsApplied == [stamp])

    let diskStore = DiskStore(baseDirectory: directory)
    let storedData = try diskStore.read(resourceID: resourceID, range: try #require(ByteRange(start: 0, endExclusive: 256)))
    #expect(storedData != Data(originData[0..<256]))

    var secondPayload = Data()
    var secondFetches = 0
    _ = try coordinator.serve(
        resourceID: resourceID,
        rangeHeader: "bytes=0-255",
        totalLength: totalLength,
        fetchNetworkRange: { _ in
            secondFetches += 1
            return Data()
        },
        emit: { secondPayload.append($0) }
    )

    #expect(secondFetches == 0)
    #expect(secondPayload == Data(originData[0..<256]))
    let secondRecord = try #require(try cache.resourceRecord(for: resourceID))
    #expect(secondRecord.pluginsApplied == [stamp])
}

@Test func proxyCacheCoordinator_offlineMode_cacheHit_servesFromDiskWithoutNetworkFallback() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-offline-hit")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 256
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 251) })
    let resourceID = try makeCoordinatorResourceID()

    let cache = CoreCache(baseDirectory: directory)
    let coordinator = ProxyCacheCoordinator(coreCache: cache)

    _ = try coordinator.serve(
        resourceID: resourceID,
        rangeHeader: "bytes=0-127",
        totalLength: totalLength,
        fetchNetworkRange: { range in
            Data(originData[Int(range.start)..<Int(range.endExclusive)])
        },
        emit: { _ in }
    )

    var payload = Data()
    var networkFetches = 0
    _ = try coordinator.serve(
        resourceID: resourceID,
        rangeHeader: "bytes=0-127",
        totalLength: totalLength,
        allowNetworkFallback: false,
        fetchNetworkRange: { _ in
            networkFetches += 1
            return Data()
        },
        emit: { payload.append($0) }
    )

    #expect(networkFetches == 0)
    #expect(payload == Data(originData[0..<128]))
}

@Test func proxyCacheCoordinator_offlineMode_cacheMiss_throwsWithoutNetworkFallback() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-offline-miss")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let cache = CoreCache(baseDirectory: directory)
    let coordinator = ProxyCacheCoordinator(coreCache: cache)
    let resourceID = try makeCoordinatorResourceID()
    var networkFetches = 0

    do {
        _ = try coordinator.serve(
            resourceID: resourceID,
            rangeHeader: "bytes=0-127",
            totalLength: 256,
            allowNetworkFallback: false,
            fetchNetworkRange: { _ in
                networkFetches += 1
                return Data(repeating: 0xAA, count: 128)
            },
            emit: { _ in }
        )
        #expect(Bool(false))
    } catch let error as ProxyCacheCoordinatorError {
        #expect(networkFetches == 0)
        #expect(error == .offlineCacheMiss(range: try #require(ByteRange(start: 0, endExclusive: 128))))
    }
}
