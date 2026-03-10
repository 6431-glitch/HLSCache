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
    let firstResponse = try ProxyRangeResponse.make(rangeHeader: "bytes=0-511", totalLength: totalLength)
    let firstRequest = firstResponse.requestedRange
    #expect(firstRequest.toHTTPHeaderValue(totalLength: totalLength) == "bytes=0-511")
    #expect(firstResponse.statusCode == 206)
    #expect(firstResponse.headers["Accept-Ranges"] == "bytes")
    #expect(firstResponse.headers["Content-Range"] == "bytes 0-511/2048")
    #expect(firstResponse.headers["Content-Length"] == "512")

    let cache = CoreCache(baseDirectory: directory)
    let resourceID = makeMP4ResourceID(cacheKey: record.cacheKey, remoteURL: remoteURL)

    let firstPlan = try cache.plan(resource: resourceID, requested: firstRequest)
    #expect(firstPlan == [.network(firstRequest)])

    _ = try cache.write(Data(repeating: 7, count: Int(firstRequest.length)), resource: resourceID, at: firstRequest.start)
    _ = try cache.finalizeWrite(resource: resourceID, expectedLength: totalLength)

    let secondResponse = try ProxyRangeResponse.make(rangeHeader: "bytes=256-767", totalLength: totalLength)
    let secondRequest = secondResponse.requestedRange
    #expect(secondRequest.toHTTPHeaderValue(totalLength: totalLength) == "bytes=256-767")
    #expect(secondResponse.statusCode == 206)
    #expect(secondResponse.headers["Content-Range"] == "bytes 256-767/2048")

    let cachedSubrange = try #require(ByteRange(start: 256, endExclusive: 512))
    let missingSubrange = try #require(ByteRange(start: 512, endExclusive: 768))
    let secondPlan = try cache.plan(resource: resourceID, requested: secondRequest)
    #expect(secondPlan == [.file(cachedSubrange), .network(missingSubrange)])

    _ = try cache.write(Data(repeating: 9, count: Int(missingSubrange.length)), resource: resourceID, at: missingSubrange.start)
    _ = try cache.finalizeWrite(resource: resourceID, expectedLength: totalLength)

    let thirdPlan = try cache.plan(resource: resourceID, requested: secondRequest)
    #expect(thirdPlan == [.file(secondRequest)])
}
