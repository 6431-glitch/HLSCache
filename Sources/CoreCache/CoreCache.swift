import Foundation

public enum ReadPlanPart: Equatable, Sendable {
    case file(ByteRange)
    case network(ByteRange)
}

public struct AssetCacheCompletionMetric: Equatable, Sendable {
    public let cacheKey: CacheKey
    public let resourceCount: Int
    public let completedBytes: Int64
    public let expectedBytes: Int64
    public let completionRatio: Double

    public init(
        cacheKey: CacheKey,
        resourceCount: Int,
        completedBytes: Int64,
        expectedBytes: Int64,
        completionRatio: Double
    ) {
        self.cacheKey = cacheKey
        self.resourceCount = resourceCount
        self.completedBytes = completedBytes
        self.expectedBytes = expectedBytes
        self.completionRatio = completionRatio
    }
}

public struct CoreCacheMetrics: Equatable, Sendable {
    public let totalRequests: Int64
    public let fullHitRequests: Int64
    public let partialHitRequests: Int64
    public let missRequests: Int64
    public let requestedBytes: Int64
    public let bytesPlannedFromCache: Int64
    public let bytesPlannedFromNetwork: Int64
    public let hitRatio: Double
    public let totalBytesOnDisk: Int64
    public let assets: [AssetCacheCompletionMetric]

    public init(
        totalRequests: Int64,
        fullHitRequests: Int64,
        partialHitRequests: Int64,
        missRequests: Int64,
        requestedBytes: Int64,
        bytesPlannedFromCache: Int64,
        bytesPlannedFromNetwork: Int64,
        hitRatio: Double,
        totalBytesOnDisk: Int64,
        assets: [AssetCacheCompletionMetric]
    ) {
        self.totalRequests = totalRequests
        self.fullHitRequests = fullHitRequests
        self.partialHitRequests = partialHitRequests
        self.missRequests = missRequests
        self.requestedBytes = requestedBytes
        self.bytesPlannedFromCache = bytesPlannedFromCache
        self.bytesPlannedFromNetwork = bytesPlannedFromNetwork
        self.hitRatio = hitRatio
        self.totalBytesOnDisk = totalBytesOnDisk
        self.assets = assets
    }
}

public final class CoreCache: @unchecked Sendable {
    private struct PlanMetricsAccumulator {
        var totalRequests: Int64 = 0
        var fullHitRequests: Int64 = 0
        var partialHitRequests: Int64 = 0
        var missRequests: Int64 = 0
        var requestedBytes: Int64 = 0
        var bytesPlannedFromCache: Int64 = 0
        var bytesPlannedFromNetwork: Int64 = 0
    }

    // Single synchronization strategy for mutable CoreCache state.
    // Reads use queue.sync; all mutations use barrier writes.
    private let queue = DispatchQueue(label: "CoreCache.CoreCache", attributes: .concurrent)
    private let diskStore: DiskStore
    private let manifestStore: ManifestStore
    private let diskQuotaBytes: Int64?
    private let logger: any StructuredLogger
    private let metricsLock = NSLock()
    private var planMetrics = PlanMetricsAccumulator()

    public init(
        baseDirectory: URL,
        diskQuotaBytes: Int64? = nil,
        logger: any StructuredLogger = NoopStructuredLogger()
    ) {
        self.diskStore = DiskStore(baseDirectory: baseDirectory)
        self.manifestStore = ManifestStore(baseDirectory: baseDirectory)
        self.diskQuotaBytes = diskQuotaBytes.map { max($0, 0) }
        self.logger = logger
    }

    public func plan(resource: ResourceID, requested: ByteRange) throws -> [ReadPlanPart] {
        let correlationID = UUID().uuidString
        return try queue.sync {
            guard requested.length > 0 else {
                return []
            }

            let parts: [ReadPlanPart]
            if let record = try manifestStore.load(resourceID: resource) {
                let missingRanges = record.completedRanges.missingSubranges(for: requested)
                parts = validatedPlanParts(requested: requested, missingRanges: missingRanges)
            } else {
                parts = [.network(requested)]
            }

            recordPlanMetrics(parts: parts, requested: requested)
            logger.log(
                StructuredLogEvent(
                    subsystem: "CoreCache",
                    operation: "plan",
                    level: .debug,
                    correlationID: correlationID,
                    metadata: [
                        "cacheKey": resource.cacheKey.rawValue,
                        "kind": resource.kind.rawValue,
                        "parts": String(parts.count)
                    ]
                )
            )
            return parts
        }
    }

    public func metrics() throws -> CoreCacheMetrics {
        let planSnapshot: PlanMetricsAccumulator = {
            metricsLock.lock()
            defer { metricsLock.unlock() }
            return planMetrics
        }()

        return try queue.sync {
            let entries = manifestStore.allRecords()
            var bytesByResource: [ResourceID: Int64] = [:]
            var totalBytesOnDisk: Int64 = 0
            var recordsByAsset: [CacheKey: [StoredManifestRecord]] = [:]

            for entry in entries {
                let length = try diskStore.fileLength(for: entry.resourceID)
                bytesByResource[entry.resourceID] = length
                totalBytesOnDisk += length
                recordsByAsset[entry.resourceID.cacheKey, default: []].append(entry)
            }

            let assets = recordsByAsset.map { cacheKey, groupedEntries in
                let completed = groupedEntries.reduce(Int64(0)) { partial, entry in
                    partial + entry.record.completedRanges.normalized.reduce(Int64(0)) { $0 + $1.length }
                }
                let expected = groupedEntries.reduce(Int64(0)) { partial, entry in
                    let fallback = bytesByResource[entry.resourceID] ?? 0
                    return partial + (entry.record.expectedLength ?? fallback)
                }
                let ratio: Double
                if expected > 0 {
                    ratio = min(1.0, Double(completed) / Double(expected))
                } else {
                    ratio = 0
                }

                return AssetCacheCompletionMetric(
                    cacheKey: cacheKey,
                    resourceCount: groupedEntries.count,
                    completedBytes: completed,
                    expectedBytes: expected,
                    completionRatio: ratio
                )
            }
            .sorted { $0.cacheKey.rawValue < $1.cacheKey.rawValue }

            let hitRatio = planSnapshot.requestedBytes > 0
                ? Double(planSnapshot.bytesPlannedFromCache) / Double(planSnapshot.requestedBytes)
                : 0

            return CoreCacheMetrics(
                totalRequests: planSnapshot.totalRequests,
                fullHitRequests: planSnapshot.fullHitRequests,
                partialHitRequests: planSnapshot.partialHitRequests,
                missRequests: planSnapshot.missRequests,
                requestedBytes: planSnapshot.requestedBytes,
                bytesPlannedFromCache: planSnapshot.bytesPlannedFromCache,
                bytesPlannedFromNetwork: planSnapshot.bytesPlannedFromNetwork,
                hitRatio: hitRatio,
                totalBytesOnDisk: totalBytesOnDisk,
                assets: assets
            )
        }
    }

    @discardableResult
    public func write(
        _ data: Data,
        resource: ResourceID,
        at offset: Int64,
        contentType: String? = nil,
        expectedLength: Int64? = nil,
        pluginsApplied: [PluginStamp]? = nil
    ) throws -> ByteRange {
        let correlationID = UUID().uuidString
        return try queue.sync(flags: .barrier) {
            let writtenRange = try diskStore.write(data, for: resource, at: offset)

            var record = try manifestStore.load(resourceID: resource) ?? ResourceRecord(kind: resource.kind)
            record.completedRanges.insert(writtenRange)

            if let expectedLength {
                record.expectedLength = expectedLength
            }
            if let contentType {
                record.contentType = contentType
            }
            if let pluginsApplied {
                record.pluginsApplied = pluginsApplied
            }

            record.touch()
            try manifestStore.save(resourceID: resource, record: record)
            try enforceDiskQuotaIfNeeded(correlationID: correlationID)
            logger.log(
                StructuredLogEvent(
                    subsystem: "CoreCache",
                    operation: "write",
                    level: .info,
                    correlationID: correlationID,
                    metadata: [
                        "cacheKey": resource.cacheKey.rawValue,
                        "kind": resource.kind.rawValue,
                        "bytes": String(data.count),
                        "offset": String(offset)
                    ]
                )
            )
            return writtenRange
        }
    }

    public func read(resource: ResourceID, range: ByteRange) throws -> Data {
        let correlationID = UUID().uuidString
        return try queue.sync {
            let data = try diskStore.read(resourceID: resource, range: range)
            logger.log(
                StructuredLogEvent(
                    subsystem: "CoreCache",
                    operation: "read",
                    level: .debug,
                    correlationID: correlationID,
                    metadata: [
                        "cacheKey": resource.cacheKey.rawValue,
                        "kind": resource.kind.rawValue,
                        "bytes": String(data.count),
                        "start": String(range.start),
                        "endExclusive": String(range.endExclusive)
                    ]
                )
            )
            return data
        }
    }

    @discardableResult
    public func finalizeWrite(
        resource: ResourceID,
        expectedLength: Int64? = nil,
        pluginsApplied: [PluginStamp]? = nil
    ) throws -> ResourceRecord {
        let correlationID = UUID().uuidString
        return try queue.sync(flags: .barrier) {
            var record = try manifestStore.load(resourceID: resource) ?? ResourceRecord(kind: resource.kind)

            if let expectedLength {
                record.expectedLength = expectedLength
            } else if record.expectedLength == nil {
                record.expectedLength = try diskStore.fileLength(for: resource)
            }
            if let pluginsApplied {
                record.pluginsApplied = pluginsApplied
            }

            record.touch()
            try manifestStore.save(resourceID: resource, record: record)
            try enforceDiskQuotaIfNeeded(correlationID: correlationID)
            logger.log(
                StructuredLogEvent(
                    subsystem: "CoreCache",
                    operation: "finalizeWrite",
                    level: .info,
                    correlationID: correlationID,
                    metadata: [
                        "cacheKey": resource.cacheKey.rawValue,
                        "kind": resource.kind.rawValue
                    ]
                )
            )
            return record
        }
    }

    public func resourceRecord(for resource: ResourceID) throws -> ResourceRecord? {
        try queue.sync {
            try manifestStore.load(resourceID: resource)
        }
    }

    private func validatedPlanParts(requested: ByteRange, missingRanges: [ByteRange]) -> [ReadPlanPart] {
        let parts = planParts(requested: requested, missingRanges: missingRanges)
        if isValidPlan(parts, within: requested) {
            return parts
        }

        // Never emit invalid planning output; fallback is coherent and safe.
        return [.network(requested)]
    }

    private func recordPlanMetrics(parts: [ReadPlanPart], requested: ByteRange) {
        let requestedBytes = requested.length
        var cacheBytes: Int64 = 0
        var networkBytes: Int64 = 0

        for part in parts {
            switch part {
            case let .file(range):
                cacheBytes += range.length
            case let .network(range):
                networkBytes += range.length
            }
        }

        metricsLock.lock()
        defer { metricsLock.unlock() }

        planMetrics.totalRequests += 1
        planMetrics.requestedBytes += requestedBytes
        planMetrics.bytesPlannedFromCache += cacheBytes
        planMetrics.bytesPlannedFromNetwork += networkBytes

        if networkBytes == 0, cacheBytes > 0 {
            planMetrics.fullHitRequests += 1
        } else if cacheBytes > 0 {
            planMetrics.partialHitRequests += 1
        } else {
            planMetrics.missRequests += 1
        }
    }

    private func enforceDiskQuotaIfNeeded(correlationID: String) throws {
        guard let diskQuotaBytes else {
            return
        }

        let entries = manifestStore.allRecords()
        guard !entries.isEmpty else {
            return
        }

        var bytesByResource: [ResourceID: Int64] = [:]
        var entriesByAsset: [CacheKey: [StoredManifestRecord]] = [:]
        var totalBytes: Int64 = 0
        for entry in entries {
            let length = try diskStore.fileLength(for: entry.resourceID)
            bytesByResource[entry.resourceID] = length
            entriesByAsset[entry.resourceID.cacheKey, default: []].append(entry)
            totalBytes += length
        }

        guard totalBytes > diskQuotaBytes else {
            return
        }

        struct AssetEvictionCandidate {
            let cacheKey: CacheKey
            let resources: [StoredManifestRecord]
            let totalBytes: Int64
            let lastUpdated: Date
        }

        var assets = entriesByAsset.map { cacheKey, resources in
            let total = resources.reduce(Int64(0)) { partial, entry in
                partial + (bytesByResource[entry.resourceID] ?? 0)
            }
            let newestUpdate = resources.map(\.record.lastUpdated).max() ?? .distantPast
            let sortedResources = resources.sorted { lhs, rhs in
                if lhs.record.lastUpdated != rhs.record.lastUpdated {
                    return lhs.record.lastUpdated < rhs.record.lastUpdated
                }
                if lhs.resourceID.kind.rawValue != rhs.resourceID.kind.rawValue {
                    return lhs.resourceID.kind.rawValue < rhs.resourceID.kind.rawValue
                }
                return lhs.resourceID.resourceKey < rhs.resourceID.resourceKey
            }
            return AssetEvictionCandidate(
                cacheKey: cacheKey,
                resources: sortedResources,
                totalBytes: total,
                lastUpdated: newestUpdate
            )
        }
        assets.sort { lhs, rhs in
            if lhs.lastUpdated != rhs.lastUpdated {
                return lhs.lastUpdated < rhs.lastUpdated
            }
            return lhs.cacheKey.rawValue < rhs.cacheKey.rawValue
        }

        for asset in assets where totalBytes > diskQuotaBytes {
            for entry in asset.resources {
                let resource = entry.resourceID
                let length = bytesByResource[resource] ?? 0

                try diskStore.remove(resourceID: resource)
                try manifestStore.delete(resourceID: resource)
                logger.log(
                    StructuredLogEvent(
                        subsystem: "CoreCache",
                        operation: "evict",
                        level: .warning,
                        correlationID: correlationID,
                        metadata: [
                            "cacheKey": resource.cacheKey.rawValue,
                            "kind": resource.kind.rawValue,
                            "bytes": String(length)
                        ]
                    )
                )
            }

            totalBytes -= asset.totalBytes
        }
    }

    private func planParts(requested: ByteRange, missingRanges: [ByteRange]) -> [ReadPlanPart] {
        guard !missingRanges.isEmpty else {
            return [.file(requested)]
        }

        var parts: [ReadPlanPart] = []
        var cursor = requested.start

        for gap in missingRanges {
            if cursor < gap.start, let fileRange = ByteRange(start: cursor, endExclusive: gap.start) {
                parts.append(.file(fileRange))
            }

            parts.append(.network(gap))
            cursor = gap.endExclusive
        }

        if cursor < requested.endExclusive, let tail = ByteRange(start: cursor, endExclusive: requested.endExclusive) {
            parts.append(.file(tail))
        }

        return parts
    }

    private func isValidPlan(_ parts: [ReadPlanPart], within requested: ByteRange) -> Bool {
        guard !parts.isEmpty else {
            return requested.length == 0
        }

        var cursor = requested.start

        for part in parts {
            let range: ByteRange
            switch part {
            case let .file(value), let .network(value):
                range = value
            }

            guard range.length > 0 else {
                return false
            }
            guard range.start == cursor else {
                return false
            }
            guard range.start >= requested.start, range.endExclusive <= requested.endExclusive else {
                return false
            }

            cursor = range.endExclusive
        }

        return cursor == requested.endExclusive
    }
}
