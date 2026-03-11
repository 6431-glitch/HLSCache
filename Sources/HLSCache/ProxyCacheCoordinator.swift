import CoreCache
import Foundation

public enum ProxyCacheCoordinatorError: Error, Equatable, Sendable {
    case invalidNetworkChunkLength(expected: Int64, actual: Int)
    case invalidComputedRange(start: Int64, endExclusive: Int64)
}

public enum ProxyStreamChunkSource: String, Equatable, Sendable {
    case cache
    case network
}

public struct ProxyStreamChunk: Equatable, Sendable {
    public let source: ProxyStreamChunkSource
    public let range: ByteRange
    public let byteCount: Int

    public init(source: ProxyStreamChunkSource, range: ByteRange, byteCount: Int) {
        self.source = source
        self.range = range
        self.byteCount = byteCount
    }
}

public struct ProxyCacheServeResult: Equatable, Sendable {
    public let response: ProxyRangeResponse
    public let chunks: [ProxyStreamChunk]
    public let totalBytesStreamed: Int64

    public init(response: ProxyRangeResponse, chunks: [ProxyStreamChunk], totalBytesStreamed: Int64) {
        self.response = response
        self.chunks = chunks
        self.totalBytesStreamed = totalBytesStreamed
    }
}

public final class ProxyCacheCoordinator: @unchecked Sendable {
    private let coreCache: CoreCache
    private let transformPipeline: TransformPipeline

    public init(coreCache: CoreCache, transformPipeline: TransformPipeline = TransformPipeline()) {
        self.coreCache = coreCache
        self.transformPipeline = transformPipeline
    }

    @discardableResult
    public func serve(
        resourceID: ResourceID,
        rangeHeader: String?,
        totalLength: Int64,
        contentType: String? = nil,
        fetchNetworkRange: (ByteRange) throws -> Data,
        emit: (Data) throws -> Void
    ) throws -> ProxyCacheServeResult {
        let response = try ProxyRangeResponse.make(rangeHeader: rangeHeader, totalLength: totalLength)
        let plan = try coreCache.plan(resource: resourceID, requested: response.requestedRange)

        var chunks: [ProxyStreamChunk] = []
        var totalStreamed: Int64 = 0
        var wroteNetworkData = false

        for part in plan {
            switch part {
            case let .network(range):
                let networkData = try fetchAndValidate(range: range, fetchNetworkRange: fetchNetworkRange)
                let writeProcessor = transformPipeline.makeProcessor(
                    context: TransformContext(resourceID: resourceID, byteOffset: range.start),
                    direction: .writeToCache
                )
                let cachePayload = try writeProcessor.process(networkData, isFinal: true)
                _ = try coreCache.write(
                    cachePayload,
                    resource: resourceID,
                    at: range.start,
                    contentType: contentType,
                    expectedLength: totalLength,
                    pluginsApplied: writeProcessor.pluginStamps
                )
                try emit(networkData)
                chunks.append(ProxyStreamChunk(source: .network, range: range, byteCount: networkData.count))
                totalStreamed += Int64(networkData.count)
                wroteNetworkData = true

            case let .file(range):
                let cachedData = try coreCache.read(resource: resourceID, range: range)
                let readProcessor = transformPipeline.makeProcessor(
                    context: TransformContext(resourceID: resourceID, byteOffset: range.start),
                    direction: .readFromCache
                )
                if cachedData.count >= Int(range.length) {
                    let expectedCount = Int(range.length)
                    let payload = Data(cachedData.prefix(expectedCount))
                    let decodedPayload = try readProcessor.process(payload, isFinal: true)
                    try emit(decodedPayload)
                    chunks.append(ProxyStreamChunk(source: .cache, range: range, byteCount: expectedCount))
                    totalStreamed += Int64(expectedCount)
                    continue
                }

                if !cachedData.isEmpty {
                    let decodedPayload = try readProcessor.process(cachedData, isFinal: true)
                    try emit(decodedPayload)
                    let availableRange = try requireRange(
                        start: range.start,
                        endExclusive: range.start + Int64(cachedData.count)
                    )
                    chunks.append(ProxyStreamChunk(source: .cache, range: availableRange, byteCount: cachedData.count))
                    totalStreamed += Int64(cachedData.count)
                }

                let missingStart = range.start + Int64(cachedData.count)
                let missingRange = try requireRange(start: missingStart, endExclusive: range.endExclusive)
                let networkData = try fetchAndValidate(range: missingRange, fetchNetworkRange: fetchNetworkRange)
                let missingWriteProcessor = transformPipeline.makeProcessor(
                    context: TransformContext(resourceID: resourceID, byteOffset: missingRange.start),
                    direction: .writeToCache
                )
                let cachePayload = try missingWriteProcessor.process(networkData, isFinal: true)
                _ = try coreCache.write(
                    cachePayload,
                    resource: resourceID,
                    at: missingRange.start,
                    contentType: contentType,
                    expectedLength: totalLength,
                    pluginsApplied: missingWriteProcessor.pluginStamps
                )
                try emit(networkData)
                chunks.append(ProxyStreamChunk(source: .network, range: missingRange, byteCount: networkData.count))
                totalStreamed += Int64(networkData.count)
                wroteNetworkData = true
            }
        }

        if wroteNetworkData {
            _ = try coreCache.finalizeWrite(resource: resourceID, expectedLength: totalLength)
        }

        return ProxyCacheServeResult(response: response, chunks: chunks, totalBytesStreamed: totalStreamed)
    }

    private func fetchAndValidate(
        range: ByteRange,
        fetchNetworkRange: (ByteRange) throws -> Data
    ) throws -> Data {
        let data = try fetchNetworkRange(range)
        guard data.count == Int(range.length) else {
            throw ProxyCacheCoordinatorError.invalidNetworkChunkLength(
                expected: range.length,
                actual: data.count
            )
        }
        return data
    }

    private func requireRange(start: Int64, endExclusive: Int64) throws -> ByteRange {
        guard let range = ByteRange(start: start, endExclusive: endExclusive) else {
            throw ProxyCacheCoordinatorError.invalidComputedRange(start: start, endExclusive: endExclusive)
        }
        return range
    }
}
