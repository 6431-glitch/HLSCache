import Foundation
import Logging

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
    public let bytesServedFromDisk: Int64
    public let bytesServedFromNetwork: Int64
    public let bytesPlannedFromCache: Int64
    public let bytesPlannedFromNetwork: Int64
    public let hitRatio: Double
    public let diskServeRatio: Double
    public let networkServeRatio: Double
    public let totalBytesOnDisk: Int64
    public let assets: [AssetCacheCompletionMetric]

    public init(
        totalRequests: Int64,
        fullHitRequests: Int64,
        partialHitRequests: Int64,
        missRequests: Int64,
        requestedBytes: Int64,
        bytesServedFromDisk: Int64,
        bytesServedFromNetwork: Int64,
        bytesPlannedFromCache: Int64,
        bytesPlannedFromNetwork: Int64,
        hitRatio: Double,
        diskServeRatio: Double,
        networkServeRatio: Double,
        totalBytesOnDisk: Int64,
        assets: [AssetCacheCompletionMetric]
    ) {
        self.totalRequests = totalRequests
        self.fullHitRequests = fullHitRequests
        self.partialHitRequests = partialHitRequests
        self.missRequests = missRequests
        self.requestedBytes = requestedBytes
        self.bytesServedFromDisk = bytesServedFromDisk
        self.bytesServedFromNetwork = bytesServedFromNetwork
        self.bytesPlannedFromCache = bytesPlannedFromCache
        self.bytesPlannedFromNetwork = bytesPlannedFromNetwork
        self.hitRatio = hitRatio
        self.diskServeRatio = diskServeRatio
        self.networkServeRatio = networkServeRatio
        self.totalBytesOnDisk = totalBytesOnDisk
        self.assets = assets
    }
}

public enum EvictionRecencyPolicy: String, Equatable, Sendable {
    case leastRecentlyUpdated
    case leastRecentlyAccessed
}

public enum StartupReconciliationMode: String, Equatable, Sendable {
    case synchronous
    case asynchronous
}

public enum StartupReconciliationState: String, Equatable, Sendable {
    case pending
    case running
    case completed
    case failed
}

public struct StartupReconciliationStatus: Equatable, Sendable {
    public let mode: StartupReconciliationMode
    public let state: StartupReconciliationState
    public let startedAt: Date?
    public let completedAt: Date?
    public let durationMilliseconds: Int64?
    public let totalUnits: Int
    public let processedUnits: Int
    public let orphanManifestCount: Int
    public let orphanDataCount: Int
    public let purgedOrphanDataBytes: Int64
    public let recoveredCorruptedManifestCount: Int
    public let purgedCorruptedManifestDataBytes: Int64
    public let errorDescription: String?

    public init(
        mode: StartupReconciliationMode,
        state: StartupReconciliationState,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        durationMilliseconds: Int64? = nil,
        totalUnits: Int = 0,
        processedUnits: Int = 0,
        orphanManifestCount: Int = 0,
        orphanDataCount: Int = 0,
        purgedOrphanDataBytes: Int64 = 0,
        recoveredCorruptedManifestCount: Int = 0,
        purgedCorruptedManifestDataBytes: Int64 = 0,
        errorDescription: String? = nil
    ) {
        self.mode = mode
        self.state = state
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationMilliseconds = durationMilliseconds
        self.totalUnits = totalUnits
        self.processedUnits = processedUnits
        self.orphanManifestCount = orphanManifestCount
        self.orphanDataCount = orphanDataCount
        self.purgedOrphanDataBytes = purgedOrphanDataBytes
        self.recoveredCorruptedManifestCount = recoveredCorruptedManifestCount
        self.purgedCorruptedManifestDataBytes = purgedCorruptedManifestDataBytes
        self.errorDescription = errorDescription
    }
}

public final class CoreCache: @unchecked Sendable, HLSLoggable {
    private struct PlanMetricsAccumulator {
        var totalRequests: Int64 = 0
        var fullHitRequests: Int64 = 0
        var partialHitRequests: Int64 = 0
        var missRequests: Int64 = 0
        var requestedBytes: Int64 = 0
        var bytesPlannedFromCache: Int64 = 0
        var bytesPlannedFromNetwork: Int64 = 0
        var bytesServedFromDisk: Int64 = 0
        var bytesServedFromNetwork: Int64 = 0
    }

    // Single synchronization strategy for mutable CoreCache state.
    // Reads use queue.sync; all mutations use barrier writes.
    private let queue = DispatchQueue(label: "CoreCache.CoreCache", attributes: .concurrent)
    private let directoryLock: DirectoryLock
    private let diskStore: DiskStore
    private let manifestStore: ManifestStore
    private let overrideLogger: Logger?
    private let diskQuotaBytes: Int64?
    private let evictionRecencyPolicy: EvictionRecencyPolicy
    private let startupReconciliationMode: StartupReconciliationMode
    private let startupReconciliationProgressInterval: Int
    private let startupReconciliationCompletionGroup = DispatchGroup()
    private var startupReconciliationStatusValue: StartupReconciliationStatus
    private var planMetrics = PlanMetricsAccumulator()

    public init(
        baseDirectory: URL,
        diskQuotaBytes: Int64? = nil,
        evictionRecencyPolicy: EvictionRecencyPolicy = .leastRecentlyUpdated,
        startupReconciliationMode: StartupReconciliationMode = .synchronous,
        startupReconciliationProgressInterval: Int = 128,
        logger: Logger? = nil
    ) throws {
        self.directoryLock = try DirectoryLock(baseDirectory: baseDirectory)
        self.diskStore = DiskStore(baseDirectory: baseDirectory)
        self.manifestStore = ManifestStore(baseDirectory: baseDirectory, logger: logger)
        self.overrideLogger = logger
        self.diskQuotaBytes = diskQuotaBytes.map { max($0, 0) }
        self.evictionRecencyPolicy = evictionRecencyPolicy
        self.startupReconciliationMode = startupReconciliationMode
        self.startupReconciliationProgressInterval = max(1, startupReconciliationProgressInterval)
        self.startupReconciliationStatusValue = StartupReconciliationStatus(
            mode: startupReconciliationMode,
            state: .pending
        )

        startupReconciliationCompletionGroup.enter()
        switch startupReconciliationMode {
        case .synchronous:
            queue.sync(flags: .barrier) {
                runStartupReconciliation()
            }
        case .asynchronous:
            queue.async(flags: .barrier) {
                self.runStartupReconciliation()
            }
        }
    }

    public func startupReconciliationStatus() -> StartupReconciliationStatus {
        queue.sync {
            startupReconciliationStatusValue
        }
    }

    @discardableResult
    public func waitForStartupReconciliation(timeout: TimeInterval = 30) -> Bool {
        startupReconciliationCompletionGroup.wait(timeout: .now() + max(timeout, 0)) == .success
    }

    public func plan(
        resource: ResourceID,
        requested: ByteRange,
        correlationID: String? = nil
    ) throws -> [ReadPlanPart] {
        // Planning mutates aggregate counters, so it runs as a barrier mutation.
        return try queue.sync(flags: .barrier) {
            guard requested.length > 0 else {
                return []
            }

            let record = try manifestStore.load(resourceID: resource)
            let parts: [ReadPlanPart]
            if let record {
                let missingRanges = record.completedRanges.missingSubranges(for: requested)
                parts = validatedPlanParts(requested: requested, missingRanges: missingRanges)
            } else {
                parts = [.network(requested)]
            }

            if evictionRecencyPolicy == .leastRecentlyAccessed,
               var accessedRecord = record,
               parts.contains(where: { if case .file = $0 { return true }; return false }) {
                accessedRecord.touch()
                try manifestStore.save(resourceID: resource, record: accessedRecord)
            }

            recordPlanMetrics(parts: parts, requested: requested)
            activeLogger.debug("Planned read for resource \(resource.resourceKey) with \(parts.count) segment(s).")
            return parts
        }
    }

    public func record(resource: ResourceID) throws -> ResourceRecord? {
        try queue.sync {
            try manifestStore.load(resourceID: resource)
        }
    }

    public func recordServedBytes(disk: Int64 = 0, network: Int64 = 0) {
        let normalizedDisk = max(Int64(0), disk)
        let normalizedNetwork = max(Int64(0), network)
        guard normalizedDisk > 0 || normalizedNetwork > 0 else {
            return
        }

        queue.sync(flags: .barrier) {
            planMetrics.bytesServedFromDisk += normalizedDisk
            planMetrics.bytesServedFromNetwork += normalizedNetwork
        }
    }

    public func metrics() throws -> CoreCacheMetrics {
        return try queue.sync {
            let planSnapshot = planMetrics
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

            let bytesServedFromDisk = planSnapshot.bytesServedFromDisk
            let bytesServedFromNetwork = planSnapshot.bytesServedFromNetwork
            let diskServeRatio = planSnapshot.requestedBytes > 0
                ? Double(bytesServedFromDisk) / Double(planSnapshot.requestedBytes)
                : 0
            let networkServeRatio = planSnapshot.requestedBytes > 0
                ? Double(bytesServedFromNetwork) / Double(planSnapshot.requestedBytes)
                : 0

            return CoreCacheMetrics(
                totalRequests: planSnapshot.totalRequests,
                fullHitRequests: planSnapshot.fullHitRequests,
                partialHitRequests: planSnapshot.partialHitRequests,
                missRequests: planSnapshot.missRequests,
                requestedBytes: planSnapshot.requestedBytes,
                bytesServedFromDisk: bytesServedFromDisk,
                bytesServedFromNetwork: bytesServedFromNetwork,
                bytesPlannedFromCache: planSnapshot.bytesPlannedFromCache,
                bytesPlannedFromNetwork: planSnapshot.bytesPlannedFromNetwork,
                hitRatio: diskServeRatio,
                diskServeRatio: diskServeRatio,
                networkServeRatio: networkServeRatio,
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
        pluginsApplied: [PluginStamp]? = nil,
        correlationID: String? = nil
    ) throws -> ByteRange {
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
            // Cached bytes changed; integrity metadata must be recalculated from the new payload.
            record.integrity = nil

            try record.validateInvariants()
            record.touch()
            try manifestStore.save(resourceID: resource, record: record)
            try enforceDiskQuotaIfNeeded()
            activeLogger.info(
                "Wrote \(data.count) byte(s) to resource \(resource.resourceKey) at offset \(offset)."
            )
            return writtenRange
        }
    }

    public func read(
        resource: ResourceID,
        range: ByteRange,
        correlationID: String? = nil
    ) throws -> Data {
        return try queue.sync {
            let data = try diskStore.read(resourceID: resource, range: range)
            activeLogger.debug("Read \(data.count) byte(s) from resource \(resource.resourceKey).")
            return data
        }
    }

    @discardableResult
    public func finalizeWrite(
        resource: ResourceID,
        expectedLength: Int64? = nil,
        pluginsApplied: [PluginStamp]? = nil,
        correlationID: String? = nil
    ) throws -> ResourceRecord {
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

            try record.validateInvariants()
            record.touch()
            try manifestStore.save(resourceID: resource, record: record)
            try enforceDiskQuotaIfNeeded()
            activeLogger.info("Finalized write for resource \(resource.resourceKey).")
            return record
        }
    }

    public func resourceRecord(for resource: ResourceID) throws -> ResourceRecord? {
        try queue.sync {
            try manifestStore.load(resourceID: resource)
        }
    }

    public func logPluginMigrationDecision(
        resource: ResourceID,
        decision: String,
        reason: String,
        cachedStamps: [PluginStamp],
        activeStamps: [PluginStamp],
        correlationID: String? = nil
    ) {
        queue.sync {
            activeLogger.info(
                "Plugin migration decision for resource \(resource.resourceKey): \(decision) (\(reason))."
            )
        }
    }

    @discardableResult
    public func setResourceIntegrity(
        resource: ResourceID,
        integrity: ResourceIntegrity?,
        correlationID: String? = nil
    ) throws -> ResourceRecord {
        return try queue.sync(flags: .barrier) {
            var record = try manifestStore.load(resourceID: resource) ?? ResourceRecord(kind: resource.kind)
            record.integrity = integrity
            record.touch()
            try manifestStore.save(resourceID: resource, record: record)
            activeLogger.info("Updated integrity metadata for resource \(resource.resourceKey).")
            return record
        }
    }

    public func invalidate(
        resource: ResourceID,
        reason: String? = nil,
        correlationID: String? = nil
    ) throws {
        try queue.sync(flags: .barrier) {
            let bytes = try diskStore.fileLength(for: resource)
            try diskStore.remove(resourceID: resource)
            try manifestStore.delete(resourceID: resource)
            activeLogger.warning(
                "Invalidated resource \(resource.resourceKey), removed \(bytes) byte(s), reason: \(reason ?? "unspecified")."
            )
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

    private func runStartupReconciliation() {
        let startedAt = Date()

        // Initialization enters the completion group once; every path must leave exactly once.
        defer {
            startupReconciliationCompletionGroup.leave()
        }

        startupReconciliationStatusValue = StartupReconciliationStatus(
            mode: startupReconciliationMode,
            state: .running,
            startedAt: startedAt
        )

        do {
            let manifestScan = manifestStore.scanManifestResourceIDs()
            let manifestIDs = Set(manifestScan.resourceIDs)
            let dataIDs = Set(diskStore.allStoredResourceIDs())

            let orphanManifestIDs = manifestIDs.subtracting(dataIDs).sorted(by: Self.resourceIDSort)
            let orphanDataIDs = dataIDs.subtracting(manifestIDs).sorted(by: Self.resourceIDSort)
            let totalUnits = orphanManifestIDs.count + orphanDataIDs.count

            var purgedOrphanDataBytes: Int64 = 0
            var processedUnits = 0

            activeLogger.info("Startup reconciliation started.")

            startupReconciliationStatusValue = StartupReconciliationStatus(
                mode: startupReconciliationMode,
                state: .running,
                startedAt: startedAt,
                totalUnits: totalUnits,
                processedUnits: processedUnits,
                orphanManifestCount: orphanManifestIDs.count,
                orphanDataCount: orphanDataIDs.count,
                purgedOrphanDataBytes: purgedOrphanDataBytes,
                recoveredCorruptedManifestCount: manifestScan.recoveredCorruptedManifestCount,
                purgedCorruptedManifestDataBytes: manifestScan.purgedCorruptedManifestDataBytes
            )

            func emitProgressIfNeeded(force: Bool = false) {
                guard totalUnits > 0 else {
                    return
                }
                let shouldEmit = force || (processedUnits % startupReconciliationProgressInterval == 0)
                guard shouldEmit else {
                    return
                }

                let elapsedMillis = Int64(Date().timeIntervalSince(startedAt) * 1_000)
                activeLogger.info(
                    "Startup reconciliation progress: \(processedUnits)/\(totalUnits) unit(s) in \(elapsedMillis) ms."
                )
            }

            for resourceID in orphanManifestIDs {
                try manifestStore.delete(resourceID: resourceID)
                processedUnits += 1
                startupReconciliationStatusValue = StartupReconciliationStatus(
                    mode: startupReconciliationMode,
                    state: .running,
                    startedAt: startedAt,
                    totalUnits: totalUnits,
                    processedUnits: processedUnits,
                    orphanManifestCount: orphanManifestIDs.count,
                    orphanDataCount: orphanDataIDs.count,
                    purgedOrphanDataBytes: purgedOrphanDataBytes,
                    recoveredCorruptedManifestCount: manifestScan.recoveredCorruptedManifestCount,
                    purgedCorruptedManifestDataBytes: manifestScan.purgedCorruptedManifestDataBytes
                )
                emitProgressIfNeeded()
                activeLogger.warning("Removed orphan manifest for resource \(resourceID.resourceKey).")
            }

            for resourceID in orphanDataIDs {
                let bytes = try diskStore.fileLength(for: resourceID)
                try diskStore.remove(resourceID: resourceID)
                purgedOrphanDataBytes += bytes
                processedUnits += 1
                startupReconciliationStatusValue = StartupReconciliationStatus(
                    mode: startupReconciliationMode,
                    state: .running,
                    startedAt: startedAt,
                    totalUnits: totalUnits,
                    processedUnits: processedUnits,
                    orphanManifestCount: orphanManifestIDs.count,
                    orphanDataCount: orphanDataIDs.count,
                    purgedOrphanDataBytes: purgedOrphanDataBytes,
                    recoveredCorruptedManifestCount: manifestScan.recoveredCorruptedManifestCount,
                    purgedCorruptedManifestDataBytes: manifestScan.purgedCorruptedManifestDataBytes
                )
                emitProgressIfNeeded()
                activeLogger.warning("Removed orphan data file for resource \(resourceID.resourceKey), \(bytes) byte(s).")
            }

            emitProgressIfNeeded(force: true)
            let completedAt = Date()
            let durationMillis = Int64(completedAt.timeIntervalSince(startedAt) * 1_000)

            startupReconciliationStatusValue = StartupReconciliationStatus(
                mode: startupReconciliationMode,
                state: .completed,
                startedAt: startedAt,
                completedAt: completedAt,
                durationMilliseconds: durationMillis,
                totalUnits: totalUnits,
                processedUnits: processedUnits,
                orphanManifestCount: orphanManifestIDs.count,
                orphanDataCount: orphanDataIDs.count,
                purgedOrphanDataBytes: purgedOrphanDataBytes,
                recoveredCorruptedManifestCount: manifestScan.recoveredCorruptedManifestCount,
                purgedCorruptedManifestDataBytes: manifestScan.purgedCorruptedManifestDataBytes
            )

            activeLogger.info(
                "Startup reconciliation completed in \(durationMillis) ms with \(processedUnits) cleaned unit(s)."
            )
        } catch {
            let completedAt = Date()
            let durationMillis = Int64(completedAt.timeIntervalSince(startedAt) * 1_000)
            let previous = startupReconciliationStatusValue
            startupReconciliationStatusValue = StartupReconciliationStatus(
                mode: startupReconciliationMode,
                state: .failed,
                startedAt: previous.startedAt ?? startedAt,
                completedAt: completedAt,
                durationMilliseconds: durationMillis,
                totalUnits: previous.totalUnits,
                processedUnits: previous.processedUnits,
                orphanManifestCount: previous.orphanManifestCount,
                orphanDataCount: previous.orphanDataCount,
                purgedOrphanDataBytes: previous.purgedOrphanDataBytes,
                recoveredCorruptedManifestCount: previous.recoveredCorruptedManifestCount,
                purgedCorruptedManifestDataBytes: previous.purgedCorruptedManifestDataBytes,
                errorDescription: String(describing: error)
            )
            activeLogger.error("Startup reconciliation failed: \(error.localizedDescription)")
        }
    }

    private func enforceDiskQuotaIfNeeded() throws {
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
            let recencyTimestamp: Date
        }

        var assets = entriesByAsset.map { cacheKey, resources in
            let total = resources.reduce(Int64(0)) { partial, entry in
                partial + (bytesByResource[entry.resourceID] ?? 0)
            }
            // `lastUpdated` tracks write/finalize recency by default and access recency in access-aware mode.
            let newestRecency = resources.map(\.record.lastUpdated).max() ?? .distantPast
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
                recencyTimestamp: newestRecency
            )
        }
        assets.sort { lhs, rhs in
            if lhs.recencyTimestamp != rhs.recencyTimestamp {
                return lhs.recencyTimestamp < rhs.recencyTimestamp
            }
            return lhs.cacheKey.rawValue < rhs.cacheKey.rawValue
        }

        for asset in assets where totalBytes > diskQuotaBytes {
            for entry in asset.resources {
                let resource = entry.resourceID
                let length = bytesByResource[resource] ?? 0

                try diskStore.remove(resourceID: resource)
                try manifestStore.delete(resourceID: resource)
                activeLogger.warning("Evicted resource \(resource.resourceKey) to enforce disk quota, removed \(length) byte(s).")
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

    private static func resourceIDSort(_ lhs: ResourceID, _ rhs: ResourceID) -> Bool {
        if lhs.cacheKey.rawValue != rhs.cacheKey.rawValue {
            return lhs.cacheKey.rawValue < rhs.cacheKey.rawValue
        }
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.resourceKey < rhs.resourceKey
    }

    private var activeLogger: Logger {
        overrideLogger ?? logger
    }
}
