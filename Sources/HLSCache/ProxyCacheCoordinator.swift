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
    private struct SemanticVersion: Comparable, Equatable {
        let major: Int
        let minor: Int
        let patch: Int

        static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            return lhs.patch < rhs.patch
        }
    }

    private enum PluginMigrationDecision: String {
        case exactReuse
        case compatibleReuse
        case forcedRecache
    }

    private struct PluginMigrationEvaluation {
        let decision: PluginMigrationDecision
        let reason: String
    }

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
        correlationID: String? = nil,
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
            chunkSizeBytes: .max,
            correlationID: correlationID
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
        correlationID: String? = nil,
        emitChunk: (ProxyStreamChunk, Data) async throws -> Void
    ) async throws -> ProxyCacheServeResult {
        let resolvedCorrelationID = correlationID ?? UUID().uuidString
        let response = try ProxyRangeResponse.make(rangeHeader: rangeHeader, totalLength: totalLength)
        if response.statusCode == 416 {
            return ProxyCacheServeResult(response: response, chunks: [], totalBytesStreamed: 0)
        }

        try invalidateResourceIfPluginStampsIncompatible(
            resourceID: resourceID,
            correlationID: resolvedCorrelationID
        )
        try invalidateResourceIfIntegrityMismatch(
            resourceID: resourceID,
            correlationID: resolvedCorrelationID
        )
        let plan = try coreCache.plan(
            resource: resourceID,
            requested: response.requestedRange,
            correlationID: resolvedCorrelationID
        )
        let normalizedChunkSize = max(Int64(1), chunkSizeBytes)

        var chunks: [ProxyStreamChunk] = []
        var totalStreamed: Int64 = 0
        var wroteNetworkData = false

        for (index, part) in plan.enumerated() {
            let isResponseFinalPart = index == plan.count - 1
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
                    isResponseFinalPart: isResponseFinalPart,
                    correlationID: resolvedCorrelationID,
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
                    isResponseFinalPart: isResponseFinalPart,
                    correlationID: resolvedCorrelationID,
                    emitChunk: emitChunk
                )
                chunks.append(contentsOf: fileResult.chunks)
                totalStreamed += fileResult.totalBytesStreamed
                wroteNetworkData = wroteNetworkData || fileResult.wroteNetworkData
            }
        }

        if wroteNetworkData {
            let record = try coreCache.finalizeWrite(
                resource: resourceID,
                expectedLength: totalLength,
                correlationID: resolvedCorrelationID
            )
            try refreshResourceIntegrity(
                resourceID: resourceID,
                record: record,
                correlationID: resolvedCorrelationID
            )
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
        correlationID: String? = nil,
        fetchNetworkRange: (ByteRange) throws -> Data,
        emit: (Data) throws -> Void
    ) throws -> ProxyCacheServeResult {
        let resolvedCorrelationID = correlationID ?? UUID().uuidString
        let response = try ProxyRangeResponse.make(rangeHeader: rangeHeader, totalLength: totalLength)
        if response.statusCode == 416 {
            return ProxyCacheServeResult(response: response, chunks: [], totalBytesStreamed: 0)
        }
        try invalidateResourceIfPluginStampsIncompatible(
            resourceID: resourceID,
            correlationID: resolvedCorrelationID
        )
        try invalidateResourceIfIntegrityMismatch(
            resourceID: resourceID,
            correlationID: resolvedCorrelationID
        )
        let plan = try coreCache.plan(
            resource: resourceID,
            requested: response.requestedRange,
            correlationID: resolvedCorrelationID
        )

        var chunks: [ProxyStreamChunk] = []
        var totalStreamed: Int64 = 0
        var wroteNetworkData = false

        for (index, part) in plan.enumerated() {
            let isResponseFinalPart = index == plan.count - 1
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
                let cachePayload = try writeProcessor.process(networkData, isFinal: isResponseFinalPart)
                _ = try coreCache.write(
                    cachePayload,
                    resource: resourceID,
                    at: range.start,
                    contentType: contentType,
                    expectedLength: totalLength,
                    pluginsApplied: writeProcessor.pluginStamps,
                    correlationID: resolvedCorrelationID
                )
                try emit(networkData)
                coreCache.recordServedBytes(network: Int64(networkData.count))
                chunks.append(ProxyStreamChunk(source: .network, range: range, byteCount: networkData.count))
                totalStreamed += Int64(networkData.count)
                wroteNetworkData = true

            case let .file(range):
                let cachedData = try coreCache.read(
                    resource: resourceID,
                    range: range,
                    correlationID: resolvedCorrelationID
                )
                let readProcessor = transformPipeline.makeProcessor(
                    context: TransformContext(resourceID: resourceID, byteOffset: range.start),
                    direction: .readFromCache
                )
                if cachedData.count >= Int(range.length) {
                    let expectedCount = Int(range.length)
                    let payload = Data(cachedData.prefix(expectedCount))
                    let decodedPayload = try readProcessor.process(payload, isFinal: isResponseFinalPart)
                    try emit(decodedPayload)
                    coreCache.recordServedBytes(disk: Int64(decodedPayload.count))
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
                    let decodedPayload = try readProcessor.process(cachedData, isFinal: false)
                    try emit(decodedPayload)
                    coreCache.recordServedBytes(disk: Int64(decodedPayload.count))
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
                let cachePayload = try missingWriteProcessor.process(networkData, isFinal: isResponseFinalPart)
                _ = try coreCache.write(
                    cachePayload,
                    resource: resourceID,
                    at: missingRange.start,
                    contentType: contentType,
                    expectedLength: totalLength,
                    pluginsApplied: missingWriteProcessor.pluginStamps,
                    correlationID: resolvedCorrelationID
                )
                try emit(networkData)
                coreCache.recordServedBytes(network: Int64(networkData.count))
                chunks.append(ProxyStreamChunk(source: .network, range: missingRange, byteCount: networkData.count))
                totalStreamed += Int64(networkData.count)
                wroteNetworkData = true
            }
        }

        if wroteNetworkData {
            let record = try coreCache.finalizeWrite(
                resource: resourceID,
                expectedLength: totalLength,
                correlationID: resolvedCorrelationID
            )
            try refreshResourceIntegrity(
                resourceID: resourceID,
                record: record,
                correlationID: resolvedCorrelationID
            )
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

    private func invalidateResourceIfPluginStampsIncompatible(
        resourceID: ResourceID,
        correlationID: String
    ) throws {
        guard let record = try coreCache.resourceRecord(for: resourceID) else {
            return
        }
        let activeStamps = activePluginStamps(for: resourceID)
        let evaluation = evaluatePluginMigration(cached: record.pluginsApplied, active: activeStamps)
        coreCache.logPluginMigrationDecision(
            resource: resourceID,
            decision: evaluation.decision.rawValue,
            reason: evaluation.reason,
            cachedStamps: record.pluginsApplied,
            activeStamps: activeStamps,
            correlationID: correlationID
        )
        guard evaluation.decision == .forcedRecache else {
            return
        }
        try coreCache.invalidate(
            resource: resourceID,
            reason: "pluginMigration:\(evaluation.reason)",
            correlationID: correlationID
        )
    }

    private func evaluatePluginMigration(
        cached: [PluginStamp],
        active: [PluginStamp]
    ) -> PluginMigrationEvaluation {
        guard cached.count == active.count else {
            return PluginMigrationEvaluation(
                decision: .forcedRecache,
                reason: "pluginCountChanged"
            )
        }

        var foundCompatibleUpgrade = false

        for (cachedStamp, activeStamp) in zip(cached, active) {
            guard cachedStamp.id == activeStamp.id else {
                return PluginMigrationEvaluation(
                    decision: .forcedRecache,
                    reason: "pluginIDChanged"
                )
            }

            if cachedStamp.version == activeStamp.version {
                continue
            }

            guard let cachedVersion = parseSemanticVersion(cachedStamp.version),
                  let activeVersion = parseSemanticVersion(activeStamp.version) else {
                return PluginMigrationEvaluation(
                    decision: .forcedRecache,
                    reason: "nonSemanticVersionChanged"
                )
            }

            guard cachedVersion.major == activeVersion.major else {
                return PluginMigrationEvaluation(
                    decision: .forcedRecache,
                    reason: "pluginMajorVersionChanged"
                )
            }

            guard activeVersion >= cachedVersion else {
                return PluginMigrationEvaluation(
                    decision: .forcedRecache,
                    reason: "pluginVersionDowngraded"
                )
            }

            foundCompatibleUpgrade = true
        }

        return PluginMigrationEvaluation(
            decision: foundCompatibleUpgrade ? .compatibleReuse : .exactReuse,
            reason: foundCompatibleUpgrade ? "pluginVersionUpgradeWithinMajor" : "pluginStampsExactMatch"
        )
    }

    private func parseSemanticVersion(_ raw: String) -> SemanticVersion? {
        let core = raw.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(raw)
        let components = core.split(separator: ".")
        guard components.count >= 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2]) else {
            return nil
        }
        return SemanticVersion(major: major, minor: minor, patch: patch)
    }

    private func invalidateResourceIfIntegrityMismatch(
        resourceID: ResourceID,
        correlationID: String
    ) throws {
        guard let record = try coreCache.resourceRecord(for: resourceID),
              let storedIntegrity = record.integrity else {
            return
        }

        guard let expectedLength = record.expectedLength,
              expectedLength > 0,
              let fullRange = ByteRange(start: 0, endExclusive: expectedLength),
              record.completedRanges.contains(fullRange) else {
            return
        }

        let cachedPayload = try coreCache.read(
            resource: resourceID,
            range: fullRange,
            correlationID: correlationID
        )
        let context = TransformContext(resourceID: resourceID, byteOffset: 0)
        guard let computedIntegrity = try transformPipeline.integrityMetadata(for: cachedPayload, context: context) else {
            return
        }

        if constantTimeIntegrityEquals(storedIntegrity, computedIntegrity) {
            return
        }

        if try transformPipeline.storedIntegrityMatches(
            storedIntegrity,
            cachedPayload: cachedPayload,
            context: context
        ) == true {
            _ = try coreCache.setResourceIntegrity(
                resource: resourceID,
                integrity: computedIntegrity,
                correlationID: correlationID
            )
            return
        }

        try coreCache.invalidate(
            resource: resourceID,
            reason: "integrityMismatch",
            correlationID: correlationID
        )
    }

    private func refreshResourceIntegrity(
        resourceID: ResourceID,
        record: ResourceRecord,
        correlationID: String
    ) throws {
        guard let expectedLength = record.expectedLength,
              expectedLength > 0,
              let fullRange = ByteRange(start: 0, endExclusive: expectedLength),
              record.completedRanges.contains(fullRange) else {
            if record.integrity != nil {
                _ = try coreCache.setResourceIntegrity(
                    resource: resourceID,
                    integrity: nil,
                    correlationID: correlationID
                )
            }
            return
        }

        let cachedPayload = try coreCache.read(
            resource: resourceID,
            range: fullRange,
            correlationID: correlationID
        )
        let context = TransformContext(resourceID: resourceID, byteOffset: 0)
        let integrity = try transformPipeline.integrityMetadata(for: cachedPayload, context: context)
        if !constantTimeIntegrityEquals(integrity, record.integrity) {
            _ = try coreCache.setResourceIntegrity(
                resource: resourceID,
                integrity: integrity,
                correlationID: correlationID
            )
        }
    }

    private func activePluginStamps(for resourceID: ResourceID) -> [PluginStamp] {
        transformPipeline.makeProcessor(
            context: TransformContext(resourceID: resourceID, byteOffset: 0),
            direction: .writeToCache
        )
        .pluginStamps
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
        isResponseFinalPart: Bool,
        correlationID: String,
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
            let isFinalChunk = isResponseFinalPart && chunkRange.endExclusive == range.endExclusive
            let cachePayload = try writeProcessor.process(networkData, isFinal: isFinalChunk)
            _ = try coreCache.write(
                cachePayload,
                resource: resourceID,
                at: chunkRange.start,
                contentType: contentType,
                expectedLength: totalLength,
                pluginsApplied: writeProcessor.pluginStamps,
                correlationID: correlationID
            )

            let emittedChunk = ProxyStreamChunk(source: .network, range: chunkRange, byteCount: networkData.count)
            try await emitChunk(emittedChunk, networkData)
            coreCache.recordServedBytes(network: Int64(networkData.count))
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
        isResponseFinalPart: Bool,
        correlationID: String,
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
            let cachedData = try coreCache.read(
                resource: resourceID,
                range: chunkRange,
                correlationID: correlationID
            )

            if cachedData.count >= Int(chunkRange.length) {
                let expectedCount = Int(chunkRange.length)
                let payload = Data(cachedData.prefix(expectedCount))
                let isFinalChunk = isResponseFinalPart && chunkRange.endExclusive == range.endExclusive
                let decodedPayload = try readProcessor.process(payload, isFinal: isFinalChunk)
                let emittedChunk = ProxyStreamChunk(source: .cache, range: chunkRange, byteCount: expectedCount)
                try await emitChunk(emittedChunk, decodedPayload)
                coreCache.recordServedBytes(disk: Int64(decodedPayload.count))
                chunks.append(emittedChunk)
                totalBytesStreamed += Int64(expectedCount)
                cursor = chunkRange.endExclusive
                continue
            }

            if !cachedData.isEmpty {
                let availableEnd = chunkRange.start + Int64(cachedData.count)
                let availableRange = try requireRange(start: chunkRange.start, endExclusive: availableEnd)
                let decodedPayload = try readProcessor.process(cachedData, isFinal: false)
                let emittedChunk = ProxyStreamChunk(source: .cache, range: availableRange, byteCount: cachedData.count)
                try await emitChunk(emittedChunk, decodedPayload)
                coreCache.recordServedBytes(disk: Int64(decodedPayload.count))
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
            isResponseFinalPart: isResponseFinalPart,
            correlationID: correlationID,
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
