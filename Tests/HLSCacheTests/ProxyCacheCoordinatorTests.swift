import CoreCache
import Foundation
import Testing
@testable import HLSCache

private func makeCoordinatorResourceID() throws -> ResourceID {
    let cacheKey = CacheKey.fromAssetID("asset-proxy-coordinator")
    let remoteURL = try #require(URL(string: "https://cdn.example.com/video/proxy.mp4"))
    return ResourceID(cacheKey: cacheKey, kind: .other, resourceKey: ResourceID.makeResourceKey(from: remoteURL))
}

private enum AsyncProxyCoordinatorTestError: Error, Equatable {
    case emitFailed
    case missingRangeHeader
    case invalidRangeHeader(String)
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
private actor AsyncRequestRecorder {
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        requests.append(request)
    }

    func count() -> Int {
        requests.count
    }

    func rangeHeaders() -> [String] {
        requests.compactMap { $0.value(forHTTPHeaderField: "Range") }
    }
}

private struct StampPassThroughPlugin: ByteTransformer {
    let id: String
    let version: String

    func makeStreamTransformer(context: TransformContext) -> any ByteStreamTransformer {
        StampPassThroughTransformer()
    }
}

private struct StampPassThroughTransformer: ByteStreamTransformer {
    func transform(_ chunk: Data, isFinal: Bool) throws -> Data {
        chunk
    }
}

private func parseByteRange(from request: URLRequest) throws -> ByteRange {
    guard let rangeHeader = request.value(forHTTPHeaderField: "Range") else {
        throw AsyncProxyCoordinatorTestError.missingRangeHeader
    }
    guard rangeHeader.hasPrefix("bytes=") else {
        throw AsyncProxyCoordinatorTestError.invalidRangeHeader(rangeHeader)
    }
    let payload = String(rangeHeader.dropFirst("bytes=".count))
    let parts = payload.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2,
          let start = Int64(parts[0]),
          let endInclusive = Int64(parts[1]),
          let range = ByteRange(start: start, endExclusive: endInclusive + 1) else {
        throw AsyncProxyCoordinatorTestError.invalidRangeHeader(rangeHeader)
    }
    return range
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

    let cache = try CoreCache(baseDirectory: directory)
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

    let cache = try CoreCache(baseDirectory: directory)
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

@Test func proxyCacheCoordinator_unsatisfiableRange_returns416WithoutNetworkOrCacheStreaming() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-416")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let cache = try CoreCache(baseDirectory: directory)
    let coordinator = ProxyCacheCoordinator(coreCache: cache)
    let resourceID = try makeCoordinatorResourceID()

    var networkFetches = 0
    var emittedBytes = 0
    let result = try coordinator.serve(
        resourceID: resourceID,
        rangeHeader: "bytes=2048-4096",
        totalLength: 1024,
        fetchNetworkRange: { _ in
            networkFetches += 1
            return Data()
        },
        emit: { chunk in
            emittedBytes += chunk.count
        }
    )

    #expect(result.response.statusCode == 416)
    #expect(result.response.headers["Content-Range"] == "bytes */1024")
    #expect(result.chunks.isEmpty)
    #expect(result.totalBytesStreamed == 0)
    #expect(networkFetches == 0)
    #expect(emittedBytes == 0)
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

    let cache = try CoreCache(baseDirectory: directory)
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

@Test func proxyCacheCoordinator_pluginStampCompatibility_match_keepsCacheHitBehavior() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-stamp-match")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 128
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 211) })
    let resourceID = try makeCoordinatorResourceID()
    let plugin = StampPassThroughPlugin(id: "stamp-pass-through", version: "1.0.0")

    let cache = try CoreCache(baseDirectory: directory)
    let pipeline = TransformPipeline(transformers: [plugin])
    let coordinator = ProxyCacheCoordinator(coreCache: cache, transformPipeline: pipeline)

    _ = try coordinator.serve(
        resourceID: resourceID,
        rangeHeader: "bytes=0-63",
        totalLength: totalLength,
        fetchNetworkRange: { range in
            Data(originData[Int(range.start)..<Int(range.endExclusive)])
        },
        emit: { _ in }
    )

    var networkFetches = 0
    var payload = Data()
    let secondResult = try coordinator.serve(
        resourceID: resourceID,
        rangeHeader: "bytes=0-63",
        totalLength: totalLength,
        allowNetworkFallback: false,
        fetchNetworkRange: { _ in
            networkFetches += 1
            return Data()
        },
        emit: { payload.append($0) }
    )

    #expect(networkFetches == 0)
    #expect(secondResult.chunks == [
        ProxyStreamChunk(source: .cache, range: try #require(ByteRange(start: 0, endExclusive: 64)), byteCount: 64)
    ])
    #expect(payload == Data(originData[0..<64]))
}

@Test func proxyCacheCoordinator_pluginStampMismatch_cacheHit_invalidatesAndRefetches() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-stamp-mismatch-hit")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 128
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 199) })
    let resourceID = try makeCoordinatorResourceID()
    let cache = try CoreCache(baseDirectory: directory)

    let pipelineV1 = TransformPipeline(transformers: [StampPassThroughPlugin(id: "stamp-pass-through", version: "1.0.0")])
    let coordinatorV1 = ProxyCacheCoordinator(coreCache: cache, transformPipeline: pipelineV1)
    _ = try coordinatorV1.serve(
        resourceID: resourceID,
        rangeHeader: "bytes=0-63",
        totalLength: totalLength,
        fetchNetworkRange: { range in
            Data(originData[Int(range.start)..<Int(range.endExclusive)])
        },
        emit: { _ in }
    )

    let pipelineV2 = TransformPipeline(transformers: [StampPassThroughPlugin(id: "stamp-pass-through", version: "2.0.0")])
    let coordinatorV2 = ProxyCacheCoordinator(coreCache: cache, transformPipeline: pipelineV2)

    var networkFetches = 0
    var payload = Data()
    let result = try coordinatorV2.serve(
        resourceID: resourceID,
        rangeHeader: "bytes=0-63",
        totalLength: totalLength,
        fetchNetworkRange: { range in
            networkFetches += 1
            return Data(originData[Int(range.start)..<Int(range.endExclusive)])
        },
        emit: { payload.append($0) }
    )

    #expect(networkFetches == 1)
    #expect(result.chunks == [
        ProxyStreamChunk(source: .network, range: try #require(ByteRange(start: 0, endExclusive: 64)), byteCount: 64)
    ])
    #expect(payload == Data(originData[0..<64]))

    let record = try #require(try cache.resourceRecord(for: resourceID))
    #expect(record.pluginsApplied == [PluginStamp(id: "stamp-pass-through", version: "2.0.0")])
}

@Test func proxyCacheCoordinator_pluginStampMismatch_partialHit_invalidatesAndRefetchesRequestedRange() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-stamp-mismatch-partial")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 256
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 193) })
    let resourceID = try makeCoordinatorResourceID()
    let cache = try CoreCache(baseDirectory: directory)

    let coordinatorV1 = ProxyCacheCoordinator(
        coreCache: cache,
        transformPipeline: TransformPipeline(transformers: [StampPassThroughPlugin(id: "stamp-pass-through", version: "1.0.0")])
    )
    _ = try coordinatorV1.serve(
        resourceID: resourceID,
        rangeHeader: "bytes=0-63",
        totalLength: totalLength,
        fetchNetworkRange: { range in
            Data(originData[Int(range.start)..<Int(range.endExclusive)])
        },
        emit: { _ in }
    )

    let coordinatorV2 = ProxyCacheCoordinator(
        coreCache: cache,
        transformPipeline: TransformPipeline(transformers: [StampPassThroughPlugin(id: "stamp-pass-through", version: "2.0.0")])
    )

    var networkFetches = 0
    var payload = Data()
    let result = try coordinatorV2.serve(
        resourceID: resourceID,
        rangeHeader: "bytes=0-127",
        totalLength: totalLength,
        fetchNetworkRange: { range in
            networkFetches += 1
            return Data(originData[Int(range.start)..<Int(range.endExclusive)])
        },
        emit: { payload.append($0) }
    )

    #expect(networkFetches == 1)
    #expect(result.chunks == [
        ProxyStreamChunk(source: .network, range: try #require(ByteRange(start: 0, endExclusive: 128)), byteCount: 128)
    ])
    #expect(payload == Data(originData[0..<128]))
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

    let cache = try CoreCache(baseDirectory: directory)
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

    let cache = try CoreCache(baseDirectory: directory)
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

@Test func proxyCacheCoordinator_offlineMode_partialHit_throwsExactMissingRangeWithoutNetworkFallback() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-offline-partial-miss")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 256
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 227) })
    let cache = try CoreCache(baseDirectory: directory)
    let coordinator = ProxyCacheCoordinator(coreCache: cache)
    let resourceID = try makeCoordinatorResourceID()

    _ = try coordinator.serve(
        resourceID: resourceID,
        rangeHeader: "bytes=0-63",
        totalLength: totalLength,
        fetchNetworkRange: { range in
            Data(originData[Int(range.start)..<Int(range.endExclusive)])
        },
        emit: { _ in }
    )

    var networkFetches = 0
    do {
        _ = try coordinator.serve(
            resourceID: resourceID,
            rangeHeader: "bytes=0-127",
            totalLength: totalLength,
            allowNetworkFallback: false,
            fetchNetworkRange: { _ in
                networkFetches += 1
                return Data(repeating: 0xAA, count: 64)
            },
            emit: { _ in }
        )
        #expect(Bool(false))
    } catch let error as ProxyCacheCoordinatorError {
        #expect(networkFetches == 0)
        #expect(error == .offlineCacheMiss(range: try #require(ByteRange(start: 64, endExclusive: 128))))
    }
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
@Test func proxyCacheCoordinator_asyncServe_ordersNetworkThenCacheAndPreservesPayload() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-async-serve")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 512
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 239) })
    let remoteURL = try #require(URL(string: "https://cdn.example.com/video/async.ts"))
    let requestedRange = try #require(ByteRange(start: 0, endExclusive: 128))

    let cache = try CoreCache(baseDirectory: directory)
    let coordinator = ProxyCacheCoordinator(coreCache: cache)
    let resourceID = try makeCoordinatorResourceID()
    let recorder = AsyncRequestRecorder()
    let networkClient = ClosureNetworkClient { request in
        await recorder.append(request)
        let byteRange = try parseByteRange(from: request)
        let chunk = Data(originData[Int(byteRange.start)..<Int(byteRange.endExclusive)])
        let response = try #require(
            HTTPURLResponse(
                url: remoteURL,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Range": "bytes \(byteRange.start)-\(byteRange.endExclusive - 1)/\(totalLength)"
                ]
            )
        )
        return (chunk, response)
    }

    var firstPayload = Data()
    let firstResult = try await coordinator.serve(
        resourceID: resourceID,
        remoteURL: remoteURL,
        rangeHeader: "bytes=0-127",
        totalLength: totalLength,
        networkClient: networkClient,
        emit: { firstPayload.append($0) }
    )

    #expect(firstResult.chunks == [
        ProxyStreamChunk(source: .network, range: requestedRange, byteCount: 128)
    ])
    #expect(firstPayload == Data(originData[0..<128]))
    #expect(await recorder.count() == 1)
    #expect(await recorder.rangeHeaders() == ["bytes=0-127"])

    var secondPayload = Data()
    let secondResult = try await coordinator.serve(
        resourceID: resourceID,
        remoteURL: remoteURL,
        rangeHeader: "bytes=0-127",
        totalLength: totalLength,
        allowNetworkFallback: false,
        networkClient: networkClient,
        emit: { secondPayload.append($0) }
    )

    #expect(secondResult.chunks == [
        ProxyStreamChunk(source: .cache, range: requestedRange, byteCount: 128)
    ])
    #expect(secondPayload == Data(originData[0..<128]))
    #expect(await recorder.count() == 1)
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
@Test func proxyCacheCoordinator_asyncServe_offlinePartialHit_throwsExactMissingRangeWithoutNetworkFallback() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-async-offline-partial-miss")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 256
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 223) })
    let remoteURL = try #require(URL(string: "https://cdn.example.com/video/async-offline-partial.ts"))
    let cache = try CoreCache(baseDirectory: directory)
    let coordinator = ProxyCacheCoordinator(coreCache: cache)
    let resourceID = try makeCoordinatorResourceID()
    let recorder = AsyncRequestRecorder()

    let networkClient = ClosureNetworkClient { request in
        await recorder.append(request)
        let byteRange = try parseByteRange(from: request)
        let payload = Data(originData[Int(byteRange.start)..<Int(byteRange.endExclusive)])
        let response = try #require(
            HTTPURLResponse(
                url: remoteURL,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Range": "bytes \(byteRange.start)-\(byteRange.endExclusive - 1)/\(totalLength)"
                ]
            )
        )
        return (payload, response)
    }

    _ = try await coordinator.serve(
        resourceID: resourceID,
        remoteURL: remoteURL,
        rangeHeader: "bytes=0-63",
        totalLength: totalLength,
        networkClient: networkClient,
        emit: { _ in }
    )
    #expect(await recorder.count() == 1)

    var emittedPayload = Data()
    do {
        _ = try await coordinator.serve(
            resourceID: resourceID,
            remoteURL: remoteURL,
            rangeHeader: "bytes=0-127",
            totalLength: totalLength,
            allowNetworkFallback: false,
            networkClient: networkClient,
            emit: { emittedPayload.append($0) }
        )
        #expect(Bool(false))
    } catch let error as ProxyCacheCoordinatorError {
        #expect(error == .offlineCacheMiss(range: try #require(ByteRange(start: 64, endExclusive: 128))))
    }

    #expect(emittedPayload == Data(originData[0..<64]))
    #expect(await recorder.count() == 1)
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
@Test func proxyCacheCoordinator_asyncServe_emitErrorBubbles() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-async-emit-error")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 128
    let remoteURL = try #require(URL(string: "https://cdn.example.com/video/emit-error.ts"))
    let requestedRange = try #require(ByteRange(start: 0, endExclusive: 64))
    let payload = Data(repeating: 0xAA, count: Int(requestedRange.length))
    let response = try #require(
        HTTPURLResponse(
            url: remoteURL,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Range": "bytes 0-63/\(totalLength)"]
        )
    )

    let cache = try CoreCache(baseDirectory: directory)
    let coordinator = ProxyCacheCoordinator(coreCache: cache)
    let resourceID = try makeCoordinatorResourceID()
    let networkClient = ClosureNetworkClient { _ in (payload, response) }

    do {
        _ = try await coordinator.serve(
            resourceID: resourceID,
            remoteURL: remoteURL,
            rangeHeader: "bytes=0-63",
            totalLength: totalLength,
            networkClient: networkClient,
            emit: { _ in throw AsyncProxyCoordinatorTestError.emitFailed }
        )
        #expect(Bool(false))
    } catch let error as AsyncProxyCoordinatorTestError {
        #expect(error == .emitFailed)
    }
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
@Test func proxyCacheCoordinator_streamingServe_ordersChunksAndReusesCacheWithoutNetwork() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-streaming-order")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 512
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 233) })
    let remoteURL = try #require(URL(string: "https://cdn.example.com/video/streaming-order.ts"))
    let chunkSize: Int64 = 32

    let cache = try CoreCache(baseDirectory: directory)
    let coordinator = ProxyCacheCoordinator(coreCache: cache)
    let resourceID = try makeCoordinatorResourceID()
    let recorder = AsyncRequestRecorder()

    let networkClient = ClosureNetworkClient { request in
        await recorder.append(request)
        let byteRange = try parseByteRange(from: request)
        let payload = Data(originData[Int(byteRange.start)..<Int(byteRange.endExclusive)])
        let response = try #require(
            HTTPURLResponse(
                url: remoteURL,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Range": "bytes \(byteRange.start)-\(byteRange.endExclusive - 1)/\(totalLength)"
                ]
            )
        )
        return (payload, response)
    }

    var firstEmission: [(ProxyStreamChunk, Data)] = []
    let firstResult = try await coordinator.serveStreaming(
        resourceID: resourceID,
        remoteURL: remoteURL,
        rangeHeader: "bytes=0-127",
        totalLength: totalLength,
        networkClient: networkClient,
        chunkSizeBytes: chunkSize,
        emitChunk: { chunk, payload in
            firstEmission.append((chunk, payload))
        }
    )

    let expectedRanges = [
        try #require(ByteRange(start: 0, endExclusive: 32)),
        try #require(ByteRange(start: 32, endExclusive: 64)),
        try #require(ByteRange(start: 64, endExclusive: 96)),
        try #require(ByteRange(start: 96, endExclusive: 128))
    ]
    #expect(firstResult.chunks.map(\.source) == [.network, .network, .network, .network])
    #expect(firstResult.chunks.map(\.range) == expectedRanges)
    #expect(firstResult.totalBytesStreamed == 128)

    var firstPayload = Data()
    firstEmission.forEach { firstPayload.append($0.1) }
    #expect(firstPayload == Data(originData[0..<128]))
    #expect(await recorder.rangeHeaders() == [
        "bytes=0-31",
        "bytes=32-63",
        "bytes=64-95",
        "bytes=96-127"
    ])

    var secondEmission: [(ProxyStreamChunk, Data)] = []
    let secondResult = try await coordinator.serveStreaming(
        resourceID: resourceID,
        remoteURL: remoteURL,
        rangeHeader: "bytes=0-127",
        totalLength: totalLength,
        allowNetworkFallback: false,
        networkClient: networkClient,
        chunkSizeBytes: chunkSize,
        emitChunk: { chunk, payload in
            secondEmission.append((chunk, payload))
        }
    )

    #expect(secondResult.chunks.map(\.source) == [.cache, .cache, .cache, .cache])
    #expect(secondResult.chunks.map(\.range) == expectedRanges)
    #expect(secondResult.totalBytesStreamed == 128)

    var secondPayload = Data()
    secondEmission.forEach { secondPayload.append($0.1) }
    #expect(secondPayload == Data(originData[0..<128]))
    #expect(await recorder.rangeHeaders() == [
        "bytes=0-31",
        "bytes=32-63",
        "bytes=64-95",
        "bytes=96-127"
    ])
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
@Test func proxyCacheCoordinator_streamingServe_emitErrorStopsFurtherFetches() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-streaming-error")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 512
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 229) })
    let remoteURL = try #require(URL(string: "https://cdn.example.com/video/streaming-error.ts"))
    let chunkSize: Int64 = 32

    let cache = try CoreCache(baseDirectory: directory)
    let coordinator = ProxyCacheCoordinator(coreCache: cache)
    let resourceID = try makeCoordinatorResourceID()
    let recorder = AsyncRequestRecorder()

    let networkClient = ClosureNetworkClient { request in
        await recorder.append(request)
        let byteRange = try parseByteRange(from: request)
        let payload = Data(originData[Int(byteRange.start)..<Int(byteRange.endExclusive)])
        let response = try #require(
            HTTPURLResponse(
                url: remoteURL,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Range": "bytes \(byteRange.start)-\(byteRange.endExclusive - 1)/\(totalLength)"
                ]
            )
        )
        return (payload, response)
    }

    var emittedChunkCount = 0
    do {
        _ = try await coordinator.serveStreaming(
            resourceID: resourceID,
            remoteURL: remoteURL,
            rangeHeader: "bytes=0-127",
            totalLength: totalLength,
            networkClient: networkClient,
            chunkSizeBytes: chunkSize,
            emitChunk: { _, _ in
                emittedChunkCount += 1
                if emittedChunkCount == 2 {
                    throw AsyncProxyCoordinatorTestError.emitFailed
                }
            }
        )
        #expect(Bool(false))
    } catch let error as AsyncProxyCoordinatorTestError {
        #expect(error == .emitFailed)
    }

    #expect(emittedChunkCount == 2)
    #expect(await recorder.rangeHeaders() == [
        "bytes=0-31",
        "bytes=32-63"
    ])
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
@Test func proxyCacheCoordinator_streamingServe_offlinePartialHit_throwsExactMissingRangeWithoutNetworkFallback() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-streaming-offline-partial-miss")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 256
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 219) })
    let remoteURL = try #require(URL(string: "https://cdn.example.com/video/streaming-offline-partial.ts"))
    let chunkSize: Int64 = 32

    let cache = try CoreCache(baseDirectory: directory)
    let coordinator = ProxyCacheCoordinator(coreCache: cache)
    let resourceID = try makeCoordinatorResourceID()
    let recorder = AsyncRequestRecorder()

    let networkClient = ClosureNetworkClient { request in
        await recorder.append(request)
        let byteRange = try parseByteRange(from: request)
        let payload = Data(originData[Int(byteRange.start)..<Int(byteRange.endExclusive)])
        let response = try #require(
            HTTPURLResponse(
                url: remoteURL,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Range": "bytes \(byteRange.start)-\(byteRange.endExclusive - 1)/\(totalLength)"
                ]
            )
        )
        return (payload, response)
    }

    _ = try await coordinator.serveStreaming(
        resourceID: resourceID,
        remoteURL: remoteURL,
        rangeHeader: "bytes=0-63",
        totalLength: totalLength,
        networkClient: networkClient,
        chunkSizeBytes: chunkSize,
        emitChunk: { _, _ in }
    )
    #expect(await recorder.rangeHeaders() == ["bytes=0-31", "bytes=32-63"])

    var emittedCacheRanges: [ByteRange] = []
    do {
        _ = try await coordinator.serveStreaming(
            resourceID: resourceID,
            remoteURL: remoteURL,
            rangeHeader: "bytes=0-127",
            totalLength: totalLength,
            allowNetworkFallback: false,
            networkClient: networkClient,
            chunkSizeBytes: chunkSize,
            emitChunk: { chunk, _ in
                emittedCacheRanges.append(chunk.range)
            }
        )
        #expect(Bool(false))
    } catch let error as ProxyCacheCoordinatorError {
        #expect(error == .offlineCacheMiss(range: try #require(ByteRange(start: 64, endExclusive: 128))))
    }

    #expect(emittedCacheRanges == [
        try #require(ByteRange(start: 0, endExclusive: 32)),
        try #require(ByteRange(start: 32, endExclusive: 64))
    ])
    #expect(await recorder.rangeHeaders() == ["bytes=0-31", "bytes=32-63"])
}
