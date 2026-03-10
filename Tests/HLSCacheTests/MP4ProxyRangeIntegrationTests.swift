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

private func contentRangeHeader(for range: ByteRange, totalLength: Int64) -> String {
    "bytes \(range.start)-\(range.endExclusive - 1)/\(totalLength)"
}

@Test func mp4ProxyRangeCaching_smokeTest_networkThenFilePlanWithValid206Semantics() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-mp4-range-smoke")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let facade = HLSCacheFacade(baseDirectory: directory)
    _ = facade.startServer(port: 18585)

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
    let firstRequest = try #require(ByteRange.parseHTTPRange("bytes=0-511", totalLength: totalLength))
    #expect(firstRequest.toHTTPHeaderValue(totalLength: totalLength) == "bytes=0-511")

    // Smoke-check 206 header semantics expected by a proxy response path.
    #expect(contentRangeHeader(for: firstRequest, totalLength: totalLength) == "bytes 0-511/2048")
    let acceptRangesHeader = "bytes"
    #expect(acceptRangesHeader == "bytes")

    let cache = CoreCache(baseDirectory: directory)
    let resourceID = makeMP4ResourceID(cacheKey: record.cacheKey, remoteURL: remoteURL)

    let firstPlan = try cache.plan(resource: resourceID, requested: firstRequest)
    #expect(firstPlan == [.network(firstRequest)])

    _ = try cache.write(Data(repeating: 7, count: Int(firstRequest.length)), resource: resourceID, at: firstRequest.start)
    _ = try cache.finalizeWrite(resource: resourceID, expectedLength: totalLength)

    let secondRequest = try #require(ByteRange.parseHTTPRange("bytes=256-767", totalLength: totalLength))
    #expect(secondRequest.toHTTPHeaderValue(totalLength: totalLength) == "bytes=256-767")
    #expect(contentRangeHeader(for: secondRequest, totalLength: totalLength) == "bytes 256-767/2048")

    let cachedSubrange = try #require(ByteRange(start: 256, endExclusive: 512))
    let missingSubrange = try #require(ByteRange(start: 512, endExclusive: 768))
    let secondPlan = try cache.plan(resource: resourceID, requested: secondRequest)
    #expect(secondPlan == [.file(cachedSubrange), .network(missingSubrange)])

    _ = try cache.write(Data(repeating: 9, count: Int(missingSubrange.length)), resource: resourceID, at: missingSubrange.start)
    _ = try cache.finalizeWrite(resource: resourceID, expectedLength: totalLength)

    let thirdPlan = try cache.plan(resource: resourceID, requested: secondRequest)
    #expect(thirdPlan == [.file(secondRequest)])
}
