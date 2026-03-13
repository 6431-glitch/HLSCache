import CoreCache
import Foundation

public enum ProxyCacheCoordinatorError: Error, Equatable, Sendable {
    case invalidNetworkChunkLength(expected: Int64, actual: Int)
    case invalidComputedRange(start: Int64, endExclusive: Int64)
    case offlineCacheMiss(range: ByteRange)
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

    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    public func fetchRange(
        from remoteURL: URL,
        range: ByteRange,
        headers: [String: String] = [:],
        using networkClient: any NetworkClient
    ) async throws -> Data {
        try await networkClient.data(from: remoteURL, byteRange: range, headers: headers)
    }

    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    @discardableResult
    public func serve(
        resourceID: ResourceID,
        remoteURL: URL,
        headers: [String: String] = [:],
        rangeHeader: String?,
        totalLength: Int64,
        contentType: String? = nil,
        allowNetworkFallback: Bool = true,
        networkClient: any NetworkClient,
        emit: (Data) async throws -> Void
    ) async throws -> ProxyCacheServeResult {
        try await serveStreaming(
            resourceID: resourceID,
            remoteURL: remoteURL,
            headers: headers,
            rangeHeader: rangeHeader,
            totalLength: totalLength,
            contentType: contentType,
            allowNetworkFallback: allowNetworkFallback,
            networkClient: networkClient,
            chunkSizeBytes: .max
        ) { _, payload in
            try await emit(payload)
        }
    }

    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    @discardableResult
    public func serveStreaming(
        resourceID: ResourceID,
        remoteURL: URL,
        headers: [String: String] = [:],
        rangeHeader: String?,
        totalLength: Int64,
        contentType: String? = nil,
        allowNetworkFallback: Bool = true,
        networkClient: any NetworkClient,
        chunkSizeBytes: Int64 = 256 * 1024,
        emitChunk: (ProxyStreamChunk, Data) async throws -> Void
    ) async throws -> ProxyCacheServeResult {
        let response = try ProxyRangeResponse.make(rangeHeader: rangeHeader, totalLength: totalLength)
        if response.statusCode == 416 {
            return ProxyCacheServeResult(response: response, chunks: [], totalBytesStreamed: 0)
        }

        let plan = try coreCache.plan(resource: resourceID, requested: response.requestedRange)
        let normalizedChunkSize = max(Int64(1), chunkSizeBytes)

        var chunks: [ProxyStreamChunk] = []
        var totalStreamed: Int64 = 0
        var wroteNetworkData = false

        for part in plan {
            switch part {
            case let .network(range):
                guard allowNetworkFallback else {
                    throw ProxyCacheCoordinatorError.offlineCacheMiss(range: range)
                }

                let networkResult = try await streamNetworkRange(
                    resourceID: resourceID,
                    remoteURL: remoteURL,
                    headers: headers,
                    range: range,
                    totalLength: totalLength,
                    contentType: contentType,
                    networkClient: networkClient,
                    chunkSizeBytes: normalizedChunkSize,
                    emitChunk: emitChunk
                )
                chunks.append(contentsOf: networkResult.chunks)
                totalStreamed += networkResult.totalBytesStreamed
                wroteNetworkData = true

            case let .file(range):
                let fileResult = try await streamFileRange(
                    resourceID: resourceID,
                    remoteURL: remoteURL,
                    headers: headers,
                    range: range,
                    totalLength: totalLength,
                    contentType: contentType,
                    allowNetworkFallback: allowNetworkFallback,
                    networkClient: networkClient,
                    chunkSizeBytes: normalizedChunkSize,
                    emitChunk: emitChunk
                )
                chunks.append(contentsOf: fileResult.chunks)
                totalStreamed += fileResult.totalBytesStreamed
                wroteNetworkData = wroteNetworkData || fileResult.wroteNetworkData
            }
        }

        if wroteNetworkData {
            _ = try coreCache.finalizeWrite(resource: resourceID, expectedLength: totalLength)
        }

        return ProxyCacheServeResult(response: response, chunks: chunks, totalBytesStreamed: totalStreamed)
    }

    @discardableResult
    public func serve(
        resourceID: ResourceID,
        rangeHeader: String?,
        totalLength: Int64,
        contentType: String? = nil,
        allowNetworkFallback: Bool = true,
        fetchNetworkRange: (ByteRange) throws -> Data,
        emit: (Data) throws -> Void
    ) throws -> ProxyCacheServeResult {
        let response = try ProxyRangeResponse.make(rangeHeader: rangeHeader, totalLength: totalLength)
        if response.statusCode == 416 {
            return ProxyCacheServeResult(response: response, chunks: [], totalBytesStreamed: 0)
        }
        let plan = try coreCache.plan(resource: resourceID, requested: response.requestedRange)

        var chunks: [ProxyStreamChunk] = []
        var totalStreamed: Int64 = 0
        var wroteNetworkData = false

        for part in plan {
            switch part {
            case let .network(range):
                guard allowNetworkFallback else {
                    throw ProxyCacheCoordinatorError.offlineCacheMiss(range: range)
                }
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

                let missingStart = range.start + Int64(cachedData.count)
                let missingRange = try requireRange(start: missingStart, endExclusive: range.endExclusive)
                guard allowNetworkFallback else {
                    throw ProxyCacheCoordinatorError.offlineCacheMiss(range: missingRange)
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

    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    private func streamNetworkRange(
        resourceID: ResourceID,
        remoteURL: URL,
        headers: [String: String],
        range: ByteRange,
        totalLength: Int64,
        contentType: String?,
        networkClient: any NetworkClient,
        chunkSizeBytes: Int64,
        emitChunk: (ProxyStreamChunk, Data) async throws -> Void
    ) async throws -> (chunks: [ProxyStreamChunk], totalBytesStreamed: Int64) {
        let writeProcessor = transformPipeline.makeProcessor(
            context: TransformContext(resourceID: resourceID, byteOffset: range.start),
            direction: .writeToCache
        )

        var chunks: [ProxyStreamChunk] = []
        var totalBytesStreamed: Int64 = 0
        var cursor = range.start

        while cursor < range.endExclusive {
            try Task.checkCancellation()
            let nextEnd = nextChunkEnd(start: cursor, endExclusive: range.endExclusive, chunkSizeBytes: chunkSizeBytes)
            let chunkRange = try requireRange(start: cursor, endExclusive: nextEnd)

            let networkData = try await fetchRange(
                from: remoteURL,
                range: chunkRange,
                headers: headers,
                using: networkClient
            )
            let isFinalChunk = chunkRange.endExclusive == range.endExclusive
            let cachePayload = try writeProcessor.process(networkData, isFinal: isFinalChunk)
            _ = try coreCache.write(
                cachePayload,
                resource: resourceID,
                at: chunkRange.start,
                contentType: contentType,
                expectedLength: totalLength,
                pluginsApplied: writeProcessor.pluginStamps
            )

            let emittedChunk = ProxyStreamChunk(source: .network, range: chunkRange, byteCount: networkData.count)
            try await emitChunk(emittedChunk, networkData)
            chunks.append(emittedChunk)
            totalBytesStreamed += Int64(networkData.count)
            cursor = chunkRange.endExclusive
        }

        return (chunks: chunks, totalBytesStreamed: totalBytesStreamed)
    }

    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    private func streamFileRange(
        resourceID: ResourceID,
        remoteURL: URL,
        headers: [String: String],
        range: ByteRange,
        totalLength: Int64,
        contentType: String?,
        allowNetworkFallback: Bool,
        networkClient: any NetworkClient,
        chunkSizeBytes: Int64,
        emitChunk: (ProxyStreamChunk, Data) async throws -> Void
    ) async throws -> (chunks: [ProxyStreamChunk], totalBytesStreamed: Int64, wroteNetworkData: Bool) {
        let readProcessor = transformPipeline.makeProcessor(
            context: TransformContext(resourceID: resourceID, byteOffset: range.start),
            direction: .readFromCache
        )

        var chunks: [ProxyStreamChunk] = []
        var totalBytesStreamed: Int64 = 0
        var cursor = range.start

        while cursor < range.endExclusive {
            try Task.checkCancellation()
            let nextEnd = nextChunkEnd(start: cursor, endExclusive: range.endExclusive, chunkSizeBytes: chunkSizeBytes)
            let chunkRange = try requireRange(start: cursor, endExclusive: nextEnd)
            let cachedData = try coreCache.read(resource: resourceID, range: chunkRange)

            if cachedData.count >= Int(chunkRange.length) {
                let expectedCount = Int(chunkRange.length)
                let payload = Data(cachedData.prefix(expectedCount))
                let isFinalChunk = chunkRange.endExclusive == range.endExclusive
                let decodedPayload = try readProcessor.process(payload, isFinal: isFinalChunk)
                let emittedChunk = ProxyStreamChunk(source: .cache, range: chunkRange, byteCount: expectedCount)
                try await emitChunk(emittedChunk, decodedPayload)
                chunks.append(emittedChunk)
                totalBytesStreamed += Int64(expectedCount)
                cursor = chunkRange.endExclusive
                continue
            }

            if !cachedData.isEmpty {
                let availableEnd = chunkRange.start + Int64(cachedData.count)
                let availableRange = try requireRange(start: chunkRange.start, endExclusive: availableEnd)
                let decodedPayload = try readProcessor.process(cachedData, isFinal: true)
                let emittedChunk = ProxyStreamChunk(source: .cache, range: availableRange, byteCount: cachedData.count)
                try await emitChunk(emittedChunk, decodedPayload)
                chunks.append(emittedChunk)
                totalBytesStreamed += Int64(cachedData.count)
                cursor = availableEnd
            } else {
                cursor = chunkRange.start
            }
            break
        }

        guard cursor < range.endExclusive else {
            return (chunks: chunks, totalBytesStreamed: totalBytesStreamed, wroteNetworkData: false)
        }

        let missingRange = try requireRange(start: cursor, endExclusive: range.endExclusive)
        guard allowNetworkFallback else {
            throw ProxyCacheCoordinatorError.offlineCacheMiss(range: missingRange)
        }

        let networkResult = try await streamNetworkRange(
            resourceID: resourceID,
            remoteURL: remoteURL,
            headers: headers,
            range: missingRange,
            totalLength: totalLength,
            contentType: contentType,
            networkClient: networkClient,
            chunkSizeBytes: chunkSizeBytes,
            emitChunk: emitChunk
        )
        chunks.append(contentsOf: networkResult.chunks)
        totalBytesStreamed += networkResult.totalBytesStreamed
        return (chunks: chunks, totalBytesStreamed: totalBytesStreamed, wroteNetworkData: true)
    }

    private func nextChunkEnd(start: Int64, endExclusive: Int64, chunkSizeBytes: Int64) -> Int64 {
        let remaining = endExclusive - start
        let step = min(max(Int64(1), chunkSizeBytes), remaining)
        return start + step
    }
}
