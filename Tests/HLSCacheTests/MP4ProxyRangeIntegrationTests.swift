import CoreCache
import Foundation
import Testing
@testable import HLSCache

private func makeMP4ResourceID(cacheKey: CacheKey, remoteURL: URL) -> ResourceID {
    ResourceID(
        cacheKey: cacheKey,
        kind: .other,
        resourceKey: ResourceID.makeResourceKey(from: remoteURL)
    )
}

@Test func mp4ProxyRangeCaching_smokeTest_networkThenFilePlanWithValid206Semantics() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-mp4-range-smoke")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let facade = HLSCacheFacade(baseDirectory: directory)
    _ = try facade.startServer(port: 0)

    let remoteURL = try #require(URL(string: "https://cdn.example.com/video/movie.mp4"))
    let record = try facade.register(
        alias: "MDMP4",
        assetID: "asset-mp4",
        remoteURL: remoteURL
    )

    let proxyURL = try facade.proxyURL(for: "MDMP4", kind: .raw, remoteURL: remoteURL)
    let decodedProxyRoute = try facade.decodeProxyRequestURL(proxyURL)
    #expect(decodedProxyRoute.kind == .raw)
    #expect(decodedProxyRoute.remoteURL == remoteURL)

    let totalLength: Int64 = 2048
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 251) })
    let cache = try CoreCache(baseDirectory: directory)
    let coordinator = ProxyCacheCoordinator(coreCache: cache)
    let resourceID = makeMP4ResourceID(cacheKey: record.cacheKey, remoteURL: remoteURL)

    var fetchedRanges: [ByteRange] = []
    var fetchCount = 0

    func makeFetcher() -> (ByteRange) -> Data {
        { range in
            fetchCount += 1
            fetchedRanges.append(range)
            return Data(originData[Int(range.start)..<Int(range.endExclusive)])
        }
    }

    var firstPayload = Data()
    let firstResult = try coordinator.serve(
        resourceID: resourceID,
        rangeHeader: "bytes=0-511",
        totalLength: totalLength,
        contentType: "video/mp4",
        fetchNetworkRange: makeFetcher(),
        emit: { firstPayload.append($0) }
    )
    #expect(firstResult.response.statusCode == 206)
    #expect(firstResult.response.headers["Accept-Ranges"] == "bytes")
    #expect(firstResult.response.headers["Content-Range"] == "bytes 0-511/2048")
    #expect(firstResult.response.headers["Content-Length"] == "512")
    #expect(firstResult.chunks.count == 1)
    #expect(firstResult.chunks[0].source == .network)
    #expect(fetchCount == 1)
    #expect(firstPayload == Data(originData[0..<512]))

    var secondPayload = Data()
    let cachedSubrange = try #require(ByteRange(start: 256, endExclusive: 512))
    let missingSubrange = try #require(ByteRange(start: 512, endExclusive: 768))
    let fullSecondRange = try #require(ByteRange(start: 256, endExclusive: 768))
    let secondResult = try coordinator.serve(
        resourceID: resourceID,
        rangeHeader: "bytes=256-767",
        totalLength: totalLength,
        contentType: "video/mp4",
        fetchNetworkRange: makeFetcher(),
        emit: { secondPayload.append($0) }
    )
    #expect(secondResult.response.statusCode == 206)
    #expect(secondResult.response.headers["Content-Range"] == "bytes 256-767/2048")
    #expect(secondResult.chunks == [
        ProxyStreamChunk(source: .cache, range: cachedSubrange, byteCount: 256),
        ProxyStreamChunk(source: .network, range: missingSubrange, byteCount: 256)
    ])
    #expect(fetchCount == 2)
    #expect(secondPayload == Data(originData[256..<768]))

    var thirdPayload = Data()
    let thirdResult = try coordinator.serve(
        resourceID: resourceID,
        rangeHeader: "bytes=256-767",
        totalLength: totalLength,
        contentType: "video/mp4",
        fetchNetworkRange: makeFetcher(),
        emit: { thirdPayload.append($0) }
    )
    #expect(thirdResult.chunks == [
        ProxyStreamChunk(source: .cache, range: fullSecondRange, byteCount: 512)
    ])
    #expect(fetchCount == 2)
    #expect(thirdPayload == Data(originData[256..<768]))
    let firstNetworkRange = try #require(ByteRange(start: 0, endExclusive: 512))
    #expect(fetchedRanges.contains(firstNetworkRange))
    #expect(fetchedRanges.contains(missingSubrange))
}
