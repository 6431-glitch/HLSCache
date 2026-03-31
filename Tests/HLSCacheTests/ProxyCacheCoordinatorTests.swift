import CoreCache
import Foundation
import Logging
import Testing
@testable import HLSCache

private func makeCoordinatorResourceID() throws -> ResourceID {
    let cacheKey = CacheKey.fromAssetID("asset-proxy-coordinator")
    let remoteURL = try #require(URL(string: "https://cdn.example.com/video/proxy.mp4"))
    return ResourceID(cacheKey: cacheKey, kind: .other, resourceKey: ResourceID.makeResourceKey(from: remoteURL))
}

private func legacyAuthenticatedIntegrityDigestHex(
    keyData: Data,
    resourceKeyData: Data,
    cachedPayload: Data
) -> String {
    var message = Data("hlscache-auth-integrity-v1".utf8)
    message.append(keyData)
    message.append(resourceKeyData)
    message.append(cachedPayload)
    message.append(keyData)
    return SHA256Hex.digest(message)
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

private final class LogEventStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [StructuredLogEvent] = []

    func append(_ event: StructuredLogEvent) {
        lock.lock()
        storedEvents.append(event)
        lock.unlock()
    }

    func events() -> [StructuredLogEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }
}

private struct RecordingLogHandler: LogHandler {
    let store: LogEventStore
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source _: String,
        file _: String,
        function _: String,
        line _: UInt
    ) {
        var merged = self.metadata
        if let metadata {
            for (key, value) in metadata {
                merged[key] = value
            }
        }

        let parsed = parseOperationAndMetadata(from: "\(message)")
        var parsedMetadata = parsed.metadata
        for (key, value) in merged where parsedMetadata[key] == nil {
            parsedMetadata[key] = value.stringValue
        }

        store.append(
            StructuredLogEvent(
                subsystem: merged["subsystem"]?.stringValue ?? "",
                operation: merged["operation"]?.stringValue ?? parsed.operation,
                level: level,
                correlationID: merged["correlationID"]?.stringValue ?? "n/a",
                metadata: parsedMetadata,
                timestamp: Date()
            )
        )
    }
}

private final class ProxyCoordinatorTestLogger: HLSLoggable, @unchecked Sendable {
    private let store: LogEventStore
    let logger: Logger

    init(label: String = "tests.proxyCoordinator", minimumLevel: Logger.Level = .trace) {
        let store = LogEventStore()
        self.store = store
        var built = Logger(label: label) { _ in
            RecordingLogHandler(store: store)
        }
        built.logLevel = minimumLevel
        self.logger = built
    }

    func snapshot() -> [StructuredLogEvent] {
        store.events()
    }
}

private extension Logger.MetadataValue {
    var stringValue: String {
        switch self {
        case let .string(value):
            return value
        case let .stringConvertible(value):
            return String(describing: value)
        default:
            return "\(self)"
        }
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

private struct FinalMarkerPlugin: ReversibleByteTransformer {
    let id: String = "final-marker"
    let version: String = "1.0.0"
    let marker: Data

    init(marker: Data = Data("<<FINAL>>".utf8)) {
        self.marker = marker
    }

    func makeStreamTransformer(context: TransformContext) -> any ByteStreamTransformer {
        makeStreamTransformer(context: context, direction: .writeToCache)
    }

    func makeStreamTransformer(
        context: TransformContext,
        direction: TransformDirection
    ) -> any ByteStreamTransformer {
        switch direction {
        case .writeToCache:
            return PassThroughFinalMarkerTransformer()
        case .readFromCache:
            return FinalMarkerReadTransformer(marker: marker)
        }
    }
}

private struct PassThroughFinalMarkerTransformer: ByteStreamTransformer {
    func transform(_ chunk: Data, isFinal: Bool) throws -> Data {
        chunk
    }
}

private struct FinalMarkerReadTransformer: ByteStreamTransformer {
    let marker: Data

    func transform(_ chunk: Data, isFinal: Bool) throws -> Data {
        guard isFinal else { return chunk }
        var output = Data()
        output.reserveCapacity(chunk.count + marker.count)
        output.append(chunk)
        output.append(marker)
        return output
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

    let metrics = try cache.metrics()
    #expect(metrics.totalRequests == 2)
    #expect(metrics.fullHitRequests == 1)
    #expect(metrics.partialHitRequests == 0)
    #expect(metrics.missRequests == 1)
    #expect(metrics.requestedBytes == 768)
    #expect(metrics.bytesPlannedFromCache == 256)
    #expect(metrics.bytesPlannedFromNetwork == 512)
    #expect(metrics.bytesServedFromDisk == 44)
    #expect(metrics.bytesServedFromNetwork == 724)
    #expect(abs(metrics.diskServeRatio - (44.0 / 768.0)) < 0.000_000_1)
    #expect(abs(metrics.networkServeRatio - (724.0 / 768.0)) < 0.000_000_1)
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

@Test func proxyCacheCoordinator_encryptAtRest_invalidKey_throwsRecoverableValidationError() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-encrypt-invalid-key")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 128
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 251) })
    let resourceID = try makeCoordinatorResourceID()
    let cache = try CoreCache(baseDirectory: directory)
    let pipeline = TransformPipeline(transformers: [EncryptAtRestPlugin(key: Data())])
    let coordinator = ProxyCacheCoordinator(coreCache: cache, transformPipeline: pipeline)

    do {
        _ = try coordinator.serve(
            resourceID: resourceID,
            rangeHeader: "bytes=0-63",
            totalLength: totalLength,
            fetchNetworkRange: { range in
                Data(originData[Int(range.start)..<Int(range.endExclusive)])
            },
            emit: { _ in }
        )
        #expect(Bool(false))
    } catch let error as EncryptAtRestPluginError {
        #expect(error == .invalidKey(reason: "EncryptAtRestPlugin requires a non-empty key"))
    }
}

@Test func proxyCacheCoordinator_authenticatedEncryptAtRest_tamperedCache_invalidatesAndFailsOfflineDeterministically() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-encrypt-auth")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 256
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 173) })
    let resourceID = try makeCoordinatorResourceID()

    let cache = try CoreCache(baseDirectory: directory)
    let pipeline = TransformPipeline(
        transformers: [
            EncryptAtRestPlugin(key: Data("authenticated-encrypt-key".utf8), mode: .authenticatedV1)
        ]
    )
    let coordinator = ProxyCacheCoordinator(coreCache: cache, transformPipeline: pipeline)

    _ = try coordinator.serve(
        resourceID: resourceID,
        rangeHeader: "bytes=0-255",
        totalLength: totalLength,
        fetchNetworkRange: { range in
            Data(originData[Int(range.start)..<Int(range.endExclusive)])
        },
        emit: { _ in }
    )

    let record = try #require(try cache.resourceRecord(for: resourceID))
    #expect(record.pluginsApplied == [PluginStamp(id: "encrypt-at-rest-authenticated", version: "2.0.0-auth-v1")])
    #expect(record.integrity != nil)

    let diskStore = DiskStore(baseDirectory: directory)
    let fileURL = diskStore.dataFileURL(for: resourceID)
    let fileHandle = try FileHandle(forWritingTo: fileURL)
    try fileHandle.seek(toOffset: 10)
    try fileHandle.write(contentsOf: Data([0xA7]))
    try fileHandle.close()

    var networkFetches = 0
    do {
        _ = try coordinator.serve(
            resourceID: resourceID,
            rangeHeader: "bytes=0-255",
            totalLength: totalLength,
            allowNetworkFallback: false,
            fetchNetworkRange: { _ in
                networkFetches += 1
                return Data()
            },
            emit: { _ in }
        )
        #expect(Bool(false))
    } catch let error as ProxyCacheCoordinatorError {
        #expect(error == .offlineCacheMiss(range: try #require(ByteRange(start: 0, endExclusive: 256))))
    }

    #expect(networkFetches == 0)
    #expect(try cache.resourceRecord(for: resourceID) == nil)
}

@Test func proxyCacheCoordinator_authenticatedEncryptAtRest_legacyIntegrityMetadata_isAcceptedAndMigratedToRfcHMAC() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-encrypt-auth-legacy-metadata")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let keyData = Data("authenticated-encrypt-key".utf8)
    let totalLength: Int64 = 256
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 173) })
    let resourceID = try makeCoordinatorResourceID()

    let cache = try CoreCache(baseDirectory: directory)
    let pipeline = TransformPipeline(
        transformers: [
            EncryptAtRestPlugin(key: keyData, mode: .authenticatedV1)
        ]
    )
    let coordinator = ProxyCacheCoordinator(coreCache: cache, transformPipeline: pipeline)

    _ = try coordinator.serve(
        resourceID: resourceID,
        rangeHeader: "bytes=0-255",
        totalLength: totalLength,
        fetchNetworkRange: { range in
            Data(originData[Int(range.start)..<Int(range.endExclusive)])
        },
        emit: { _ in }
    )

    let fullRange = try #require(ByteRange(start: 0, endExclusive: totalLength))
    let cachedPayload = try cache.read(resource: resourceID, range: fullRange, correlationID: "legacyIntegritySetup")
    let legacyIntegrity = ResourceIntegrity(
        algorithm: "hmac-sha256-v1",
        digestHex: legacyAuthenticatedIntegrityDigestHex(
            keyData: keyData,
            resourceKeyData: Data(resourceID.resourceKey.utf8),
            cachedPayload: cachedPayload
        )
    )
    _ = try cache.setResourceIntegrity(
        resource: resourceID,
        integrity: legacyIntegrity,
        correlationID: "legacyIntegritySetup"
    )

    let initialRfcIntegrity = try #require(
        try pipeline.integrityMetadata(
            for: cachedPayload,
            context: TransformContext(resourceID: resourceID, byteOffset: 0)
        )
    )

    var networkFetches = 0
    var payload = Data()
    _ = try coordinator.serve(
        resourceID: resourceID,
        rangeHeader: "bytes=0-255",
        totalLength: totalLength,
        allowNetworkFallback: false,
        fetchNetworkRange: { _ in
            networkFetches += 1
            return Data()
        },
        emit: { payload.append($0) }
    )

    #expect(networkFetches == 0)
    #expect(payload == originData)
    let migratedRecord = try #require(try cache.resourceRecord(for: resourceID))
    #expect(migratedRecord.integrity == initialRfcIntegrity)
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

    let logger = ProxyCoordinatorTestLogger()
    let cache = try CoreCache(baseDirectory: directory, logger: logger.logger)
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

    let migrationEvents = logger.snapshot().filter { $0.operation == "pluginMigrationDecision" }
    let exactReuseEvent = migrationEvents.last
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

@Test func proxyCacheCoordinator_pluginStampCompatibility_minorVersionUpgrade_reusesCacheAndLogsDecision() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-stamp-compatible-upgrade")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 128
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 197) })
    let resourceID = try makeCoordinatorResourceID()
    let logger = ProxyCoordinatorTestLogger()
    let cache = try CoreCache(baseDirectory: directory, logger: logger.logger)

    let coordinatorV100 = ProxyCacheCoordinator(
        coreCache: cache,
        transformPipeline: TransformPipeline(transformers: [StampPassThroughPlugin(id: "stamp-pass-through", version: "1.0.0")])
    )
    _ = try coordinatorV100.serve(
        resourceID: resourceID,
        rangeHeader: "bytes=0-63",
        totalLength: totalLength,
        fetchNetworkRange: { range in
            Data(originData[Int(range.start)..<Int(range.endExclusive)])
        },
        emit: { _ in }
    )

    let coordinatorV110 = ProxyCacheCoordinator(
        coreCache: cache,
        transformPipeline: TransformPipeline(transformers: [StampPassThroughPlugin(id: "stamp-pass-through", version: "1.1.0")])
    )

    var networkFetches = 0
    var payload = Data()
    let result = try coordinatorV110.serve(
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
    #expect(result.chunks == [
        ProxyStreamChunk(source: .cache, range: try #require(ByteRange(start: 0, endExclusive: 64)), byteCount: 64)
    ])
    #expect(payload == Data(originData[0..<64]))

    let migrationEvents = logger.snapshot().filter { $0.operation == "pluginMigrationDecision" }
    let compatibleEvent = migrationEvents.last
}

@Test func proxyCacheCoordinator_pluginMigration_forcedRecacheReasons_logTelemetryAndInvalidate() throws {
    struct ForcedRecacheCase {
        let name: String
        let cachedPlugins: [StampPassThroughPlugin]
        let activePlugins: [StampPassThroughPlugin]
        let expectedReason: String
    }

    // Regression matrix: each incompatibility path must force recache and surface
    // a stable telemetry reason for analytics and rollout diagnostics.
    let cases: [ForcedRecacheCase] = [
        ForcedRecacheCase(
            name: "plugin-count-changed",
            cachedPlugins: [StampPassThroughPlugin(id: "stamp-pass-through", version: "1.0.0")],
            activePlugins: [
                StampPassThroughPlugin(id: "stamp-pass-through", version: "1.0.0"),
                StampPassThroughPlugin(id: "stamp-pass-through-extra", version: "1.0.0")
            ],
            expectedReason: "pluginCountChanged"
        ),
        ForcedRecacheCase(
            name: "plugin-id-changed",
            cachedPlugins: [StampPassThroughPlugin(id: "stamp-pass-through-a", version: "1.0.0")],
            activePlugins: [StampPassThroughPlugin(id: "stamp-pass-through-b", version: "1.0.0")],
            expectedReason: "pluginIDChanged"
        ),
        ForcedRecacheCase(
            name: "non-semver-transition",
            cachedPlugins: [StampPassThroughPlugin(id: "stamp-pass-through", version: "1.0.0")],
            activePlugins: [StampPassThroughPlugin(id: "stamp-pass-through", version: "v1")],
            expectedReason: "nonSemanticVersionChanged"
        ),
        ForcedRecacheCase(
            name: "major-changed",
            cachedPlugins: [StampPassThroughPlugin(id: "stamp-pass-through", version: "1.2.3")],
            activePlugins: [StampPassThroughPlugin(id: "stamp-pass-through", version: "2.0.0")],
            expectedReason: "pluginMajorVersionChanged"
        ),
        ForcedRecacheCase(
            name: "downgraded",
            cachedPlugins: [StampPassThroughPlugin(id: "stamp-pass-through", version: "1.2.3")],
            activePlugins: [StampPassThroughPlugin(id: "stamp-pass-through", version: "1.2.2")],
            expectedReason: "pluginVersionDowngraded"
        )
    ]

    let totalLength: Int64 = 128
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 181) })

    for testCase in cases {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hlscache-proxy-coordinator-forced-recache-\(testCase.name)")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let logger = ProxyCoordinatorTestLogger()
        let cache = try CoreCache(baseDirectory: directory, logger: logger.logger)
        let resourceID = try makeCoordinatorResourceID()

        let cachedCoordinator = ProxyCacheCoordinator(
            coreCache: cache,
            transformPipeline: TransformPipeline(transformers: testCase.cachedPlugins)
        )
        _ = try cachedCoordinator.serve(
            resourceID: resourceID,
            rangeHeader: "bytes=0-63",
            totalLength: totalLength,
            fetchNetworkRange: { range in
                Data(originData[Int(range.start)..<Int(range.endExclusive)])
            },
            emit: { _ in }
        )

        let activeCoordinator = ProxyCacheCoordinator(
            coreCache: cache,
            transformPipeline: TransformPipeline(transformers: testCase.activePlugins)
        )
        var payload = Data()
        var networkFetches = 0
        let result = try activeCoordinator.serve(
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

        let events = logger.snapshot()
        let migrationEvent = events.last { $0.operation == "pluginMigrationDecision" }

        let invalidateEvent = events.last {
            $0.operation == "invalidateResource"
        }

        let record = try #require(try cache.resourceRecord(for: resourceID))
        #expect(record.pluginsApplied == testCase.activePlugins.map { PluginStamp(id: $0.id, version: $0.version) })
    }
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
@Test func proxyCacheCoordinator_asyncServe_pluginStampMismatch_cacheHit_invalidatesAndRefetches() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-async-stamp-mismatch-hit")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 256
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 187) })
    let remoteURL = try #require(URL(string: "https://cdn.example.com/video/async-stamp-mismatch.ts"))
    let resourceID = try makeCoordinatorResourceID()
    let cache = try CoreCache(baseDirectory: directory)

    let recorderV1 = AsyncRequestRecorder()
    let networkClientV1 = ClosureNetworkClient { request in
        await recorderV1.append(request)
        let range = try parseByteRange(from: request)
        let payload = Data(originData[Int(range.start)..<Int(range.endExclusive)])
        let response = try #require(
            HTTPURLResponse(
                url: remoteURL,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes \(range.start)-\(range.endExclusive - 1)/\(totalLength)"]
            )
        )
        return (payload, response)
    }

    let coordinatorV1 = ProxyCacheCoordinator(
        coreCache: cache,
        transformPipeline: TransformPipeline(transformers: [StampPassThroughPlugin(id: "stamp-pass-through", version: "1.0.0")])
    )
    _ = try await coordinatorV1.serve(
        resourceID: resourceID,
        remoteURL: remoteURL,
        rangeHeader: "bytes=0-127",
        totalLength: totalLength,
        networkClient: networkClientV1,
        emit: { _ in }
    )
    #expect(await recorderV1.count() == 1)

    let recorderV2 = AsyncRequestRecorder()
    let networkClientV2 = ClosureNetworkClient { request in
        await recorderV2.append(request)
        let range = try parseByteRange(from: request)
        let payload = Data(originData[Int(range.start)..<Int(range.endExclusive)])
        let response = try #require(
            HTTPURLResponse(
                url: remoteURL,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes \(range.start)-\(range.endExclusive - 1)/\(totalLength)"]
            )
        )
        return (payload, response)
    }

    let coordinatorV2 = ProxyCacheCoordinator(
        coreCache: cache,
        transformPipeline: TransformPipeline(transformers: [StampPassThroughPlugin(id: "stamp-pass-through", version: "2.0.0")])
    )

    var payload = Data()
    let result = try await coordinatorV2.serve(
        resourceID: resourceID,
        remoteURL: remoteURL,
        rangeHeader: "bytes=0-127",
        totalLength: totalLength,
        networkClient: networkClientV2,
        emit: { payload.append($0) }
    )

    #expect(result.chunks == [
        ProxyStreamChunk(source: .network, range: try #require(ByteRange(start: 0, endExclusive: 128)), byteCount: 128)
    ])
    #expect(payload == Data(originData[0..<128]))
    #expect(await recorderV2.count() == 1)

    let record = try #require(try cache.resourceRecord(for: resourceID))
    #expect(record.pluginsApplied == [PluginStamp(id: "stamp-pass-through", version: "2.0.0")])
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
@Test func proxyCacheCoordinator_asyncServe_pluginStampMismatch_offlineFallbackDisabled_throwsWithoutNetwork() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-async-stamp-mismatch-offline")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 256
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 173) })
    let remoteURL = try #require(URL(string: "https://cdn.example.com/video/async-stamp-mismatch-offline.ts"))
    let resourceID = try makeCoordinatorResourceID()
    let cache = try CoreCache(baseDirectory: directory)

    let recorderV1 = AsyncRequestRecorder()
    let networkClientV1 = ClosureNetworkClient { request in
        await recorderV1.append(request)
        let range = try parseByteRange(from: request)
        let payload = Data(originData[Int(range.start)..<Int(range.endExclusive)])
        let response = try #require(
            HTTPURLResponse(
                url: remoteURL,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes \(range.start)-\(range.endExclusive - 1)/\(totalLength)"]
            )
        )
        return (payload, response)
    }

    let coordinatorV1 = ProxyCacheCoordinator(
        coreCache: cache,
        transformPipeline: TransformPipeline(transformers: [StampPassThroughPlugin(id: "stamp-pass-through", version: "1.0.0")])
    )
    _ = try await coordinatorV1.serve(
        resourceID: resourceID,
        remoteURL: remoteURL,
        rangeHeader: "bytes=0-127",
        totalLength: totalLength,
        networkClient: networkClientV1,
        emit: { _ in }
    )
    #expect(await recorderV1.count() == 1)

    let recorderV2 = AsyncRequestRecorder()
    let networkClientV2 = ClosureNetworkClient { request in
        await recorderV2.append(request)
        let range = try parseByteRange(from: request)
        let payload = Data(originData[Int(range.start)..<Int(range.endExclusive)])
        let response = try #require(
            HTTPURLResponse(
                url: remoteURL,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes \(range.start)-\(range.endExclusive - 1)/\(totalLength)"]
            )
        )
        return (payload, response)
    }

    let coordinatorV2 = ProxyCacheCoordinator(
        coreCache: cache,
        transformPipeline: TransformPipeline(transformers: [StampPassThroughPlugin(id: "stamp-pass-through", version: "2.0.0")])
    )

    do {
        _ = try await coordinatorV2.serve(
            resourceID: resourceID,
            remoteURL: remoteURL,
            rangeHeader: "bytes=0-127",
            totalLength: totalLength,
            allowNetworkFallback: false,
            networkClient: networkClientV2,
            emit: { _ in }
        )
        #expect(Bool(false))
    } catch let error as ProxyCacheCoordinatorError {
        #expect(error == .offlineCacheMiss(range: try #require(ByteRange(start: 0, endExclusive: 128))))
    }

    #expect(await recorderV2.count() == 0)
}

@Test func proxyCacheCoordinator_isFinalSemantics_syncMixedCachePrefixAndNetworkTail_emitsUnmodifiedPayload() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-is-final-sync-mixed")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 128
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 191) })
    let resourceID = try makeCoordinatorResourceID()
    let cache = try CoreCache(baseDirectory: directory)
    let pipeline = TransformPipeline(transformers: [FinalMarkerPlugin()])
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
    let result = try coordinator.serve(
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
        ProxyStreamChunk(source: .cache, range: try #require(ByteRange(start: 0, endExclusive: 64)), byteCount: 64),
        ProxyStreamChunk(source: .network, range: try #require(ByteRange(start: 64, endExclusive: 128)), byteCount: 64)
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

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
@Test func proxyCacheCoordinator_asyncServe_authenticatedEncryptAtRest_tamperedCache_refetchesWhenFallbackAllowed() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-async-auth-tamper-refetch")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 256
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 179) })
    let remoteURL = try #require(URL(string: "https://cdn.example.com/video/async-auth-tamper-refetch.ts"))
    let resourceID = try makeCoordinatorResourceID()

    let cache = try CoreCache(baseDirectory: directory)
    let coordinator = ProxyCacheCoordinator(
        coreCache: cache,
        transformPipeline: TransformPipeline(
            transformers: [EncryptAtRestPlugin(key: Data("authenticated-async-key".utf8), mode: .authenticatedV1)]
        )
    )
    let recorder = AsyncRequestRecorder()
    let networkClient = ClosureNetworkClient { request in
        await recorder.append(request)
        let range = try parseByteRange(from: request)
        let payload = Data(originData[Int(range.start)..<Int(range.endExclusive)])
        let response = try #require(
            HTTPURLResponse(
                url: remoteURL,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes \(range.start)-\(range.endExclusive - 1)/\(totalLength)"]
            )
        )
        return (payload, response)
    }

    _ = try await coordinator.serve(
        resourceID: resourceID,
        remoteURL: remoteURL,
        rangeHeader: "bytes=0-255",
        totalLength: totalLength,
        networkClient: networkClient,
        emit: { _ in }
    )
    #expect(await recorder.count() == 1)

    let diskStore = DiskStore(baseDirectory: directory)
    let fileURL = diskStore.dataFileURL(for: resourceID)
    let fileHandle = try FileHandle(forWritingTo: fileURL)
    try fileHandle.seek(toOffset: 7)
    try fileHandle.write(contentsOf: Data([0xEE]))
    try fileHandle.close()

    var payload = Data()
    let result = try await coordinator.serve(
        resourceID: resourceID,
        remoteURL: remoteURL,
        rangeHeader: "bytes=0-127",
        totalLength: totalLength,
        networkClient: networkClient,
        emit: { payload.append($0) }
    )

    #expect(await recorder.count() == 2)
    #expect(result.chunks == [
        ProxyStreamChunk(source: .network, range: try #require(ByteRange(start: 0, endExclusive: 128)), byteCount: 128)
    ])
    #expect(payload == Data(originData[0..<128]))
    #expect((try #require(try cache.resourceRecord(for: resourceID))).pluginsApplied == [
        PluginStamp(id: "encrypt-at-rest-authenticated", version: "2.0.0-auth-v1")
    ])
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
@Test func proxyCacheCoordinator_asyncServe_authenticatedEncryptAtRest_tamperedCache_offlineFallbackDisabled_throwsWithoutNetwork() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-async-auth-tamper-offline")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 256
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 167) })
    let remoteURL = try #require(URL(string: "https://cdn.example.com/video/async-auth-tamper-offline.ts"))
    let resourceID = try makeCoordinatorResourceID()

    let cache = try CoreCache(baseDirectory: directory)
    let coordinator = ProxyCacheCoordinator(
        coreCache: cache,
        transformPipeline: TransformPipeline(
            transformers: [EncryptAtRestPlugin(key: Data("authenticated-async-key".utf8), mode: .authenticatedV1)]
        )
    )
    let recorder = AsyncRequestRecorder()
    let networkClient = ClosureNetworkClient { request in
        await recorder.append(request)
        let range = try parseByteRange(from: request)
        let payload = Data(originData[Int(range.start)..<Int(range.endExclusive)])
        let response = try #require(
            HTTPURLResponse(
                url: remoteURL,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes \(range.start)-\(range.endExclusive - 1)/\(totalLength)"]
            )
        )
        return (payload, response)
    }

    _ = try await coordinator.serve(
        resourceID: resourceID,
        remoteURL: remoteURL,
        rangeHeader: "bytes=0-255",
        totalLength: totalLength,
        networkClient: networkClient,
        emit: { _ in }
    )
    #expect(await recorder.count() == 1)

    let diskStore = DiskStore(baseDirectory: directory)
    let fileURL = diskStore.dataFileURL(for: resourceID)
    let fileHandle = try FileHandle(forWritingTo: fileURL)
    try fileHandle.seek(toOffset: 11)
    try fileHandle.write(contentsOf: Data([0xAC]))
    try fileHandle.close()

    do {
        _ = try await coordinator.serve(
            resourceID: resourceID,
            remoteURL: remoteURL,
            rangeHeader: "bytes=0-127",
            totalLength: totalLength,
            allowNetworkFallback: false,
            networkClient: networkClient,
            emit: { _ in }
        )
        #expect(Bool(false))
    } catch let error as ProxyCacheCoordinatorError {
        #expect(error == .offlineCacheMiss(range: try #require(ByteRange(start: 0, endExclusive: 128))))
    }

    #expect(await recorder.count() == 1)
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
@Test func proxyCacheCoordinator_isFinalSemantics_asyncMixedCachePrefixAndNetworkTail_emitsUnmodifiedPayload() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-is-final-async-mixed")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 256
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 181) })
    let remoteURL = try #require(URL(string: "https://cdn.example.com/video/is-final-async-mixed.ts"))
    let resourceID = try makeCoordinatorResourceID()
    let cache = try CoreCache(baseDirectory: directory)
    let pipeline = TransformPipeline(transformers: [FinalMarkerPlugin()])
    let coordinator = ProxyCacheCoordinator(coreCache: cache, transformPipeline: pipeline)
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

    var emittedPayload = Data()
    let result = try await coordinator.serveStreaming(
        resourceID: resourceID,
        remoteURL: remoteURL,
        rangeHeader: "bytes=0-127",
        totalLength: totalLength,
        networkClient: networkClient,
        chunkSizeBytes: 32,
        emitChunk: { _, payload in
            emittedPayload.append(payload)
        }
    )

    #expect(result.chunks.map(\.source) == [.cache, .cache, .network, .network])
    #expect(result.chunks.map(\.range) == [
        try #require(ByteRange(start: 0, endExclusive: 32)),
        try #require(ByteRange(start: 32, endExclusive: 64)),
        try #require(ByteRange(start: 64, endExclusive: 96)),
        try #require(ByteRange(start: 96, endExclusive: 128))
    ])
    #expect(emittedPayload == Data(originData[0..<128]))
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

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
@Test func proxyCacheCoordinator_streamingServe_pluginStampMismatch_offlineFallbackDisabled_throwsWithoutNetwork() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-streaming-stamp-mismatch-offline")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 256
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 163) })
    let remoteURL = try #require(URL(string: "https://cdn.example.com/video/streaming-stamp-mismatch-offline.ts"))
    let resourceID = try makeCoordinatorResourceID()
    let cache = try CoreCache(baseDirectory: directory)
    let chunkSize: Int64 = 32

    let recorderV1 = AsyncRequestRecorder()
    let networkClientV1 = ClosureNetworkClient { request in
        await recorderV1.append(request)
        let range = try parseByteRange(from: request)
        let payload = Data(originData[Int(range.start)..<Int(range.endExclusive)])
        let response = try #require(
            HTTPURLResponse(
                url: remoteURL,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes \(range.start)-\(range.endExclusive - 1)/\(totalLength)"]
            )
        )
        return (payload, response)
    }

    let coordinatorV1 = ProxyCacheCoordinator(
        coreCache: cache,
        transformPipeline: TransformPipeline(transformers: [StampPassThroughPlugin(id: "stamp-pass-through", version: "1.0.0")])
    )
    _ = try await coordinatorV1.serveStreaming(
        resourceID: resourceID,
        remoteURL: remoteURL,
        rangeHeader: "bytes=0-127",
        totalLength: totalLength,
        networkClient: networkClientV1,
        chunkSizeBytes: chunkSize,
        emitChunk: { _, _ in }
    )
    #expect(await recorderV1.rangeHeaders() == ["bytes=0-31", "bytes=32-63", "bytes=64-95", "bytes=96-127"])

    let recorderV2 = AsyncRequestRecorder()
    let networkClientV2 = ClosureNetworkClient { request in
        await recorderV2.append(request)
        let range = try parseByteRange(from: request)
        let payload = Data(originData[Int(range.start)..<Int(range.endExclusive)])
        let response = try #require(
            HTTPURLResponse(
                url: remoteURL,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes \(range.start)-\(range.endExclusive - 1)/\(totalLength)"]
            )
        )
        return (payload, response)
    }

    let coordinatorV2 = ProxyCacheCoordinator(
        coreCache: cache,
        transformPipeline: TransformPipeline(transformers: [StampPassThroughPlugin(id: "stamp-pass-through", version: "2.0.0")])
    )

    var emittedChunks = 0
    do {
        _ = try await coordinatorV2.serveStreaming(
            resourceID: resourceID,
            remoteURL: remoteURL,
            rangeHeader: "bytes=0-127",
            totalLength: totalLength,
            allowNetworkFallback: false,
            networkClient: networkClientV2,
            chunkSizeBytes: chunkSize,
            emitChunk: { _, _ in
                emittedChunks += 1
            }
        )
        #expect(Bool(false))
    } catch let error as ProxyCacheCoordinatorError {
        #expect(error == .offlineCacheMiss(range: try #require(ByteRange(start: 0, endExclusive: 128))))
    }

    #expect(emittedChunks == 0)
    #expect(await recorderV2.count() == 0)
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
@Test func proxyCacheCoordinator_streamingServe_authenticatedEncryptAtRest_tamperedCache_offlineFallbackDisabled_throwsWithoutNetwork() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-proxy-coordinator-streaming-auth-tamper-offline")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let totalLength: Int64 = 256
    let originData = Data((0..<Int(totalLength)).map { UInt8($0 % 157) })
    let remoteURL = try #require(URL(string: "https://cdn.example.com/video/streaming-auth-tamper-offline.ts"))
    let chunkSize: Int64 = 64
    let resourceID = try makeCoordinatorResourceID()
    let cache = try CoreCache(baseDirectory: directory)

    let coordinator = ProxyCacheCoordinator(
        coreCache: cache,
        transformPipeline: TransformPipeline(
            transformers: [EncryptAtRestPlugin(key: Data("authenticated-streaming-key".utf8), mode: .authenticatedV1)]
        )
    )
    let recorder = AsyncRequestRecorder()
    let networkClient = ClosureNetworkClient { request in
        await recorder.append(request)
        let range = try parseByteRange(from: request)
        let payload = Data(originData[Int(range.start)..<Int(range.endExclusive)])
        let response = try #require(
            HTTPURLResponse(
                url: remoteURL,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes \(range.start)-\(range.endExclusive - 1)/\(totalLength)"]
            )
        )
        return (payload, response)
    }

    _ = try await coordinator.serveStreaming(
        resourceID: resourceID,
        remoteURL: remoteURL,
        rangeHeader: "bytes=0-255",
        totalLength: totalLength,
        networkClient: networkClient,
        chunkSizeBytes: chunkSize,
        emitChunk: { _, _ in }
    )
    #expect(await recorder.rangeHeaders() == ["bytes=0-63", "bytes=64-127", "bytes=128-191", "bytes=192-255"])

    let diskStore = DiskStore(baseDirectory: directory)
    let fileURL = diskStore.dataFileURL(for: resourceID)
    let fileHandle = try FileHandle(forWritingTo: fileURL)
    try fileHandle.seek(toOffset: 9)
    try fileHandle.write(contentsOf: Data([0xD3]))
    try fileHandle.close()

    var emittedChunks = 0
    do {
        _ = try await coordinator.serveStreaming(
            resourceID: resourceID,
            remoteURL: remoteURL,
            rangeHeader: "bytes=0-127",
            totalLength: totalLength,
            allowNetworkFallback: false,
            networkClient: networkClient,
            chunkSizeBytes: chunkSize,
            emitChunk: { _, _ in
                emittedChunks += 1
            }
        )
        #expect(Bool(false))
    } catch let error as ProxyCacheCoordinatorError {
        #expect(error == .offlineCacheMiss(range: try #require(ByteRange(start: 0, endExclusive: 128))))
    }

    #expect(emittedChunks == 0)
    #expect(await recorder.rangeHeaders() == ["bytes=0-63", "bytes=64-127", "bytes=128-191", "bytes=192-255"])
}
