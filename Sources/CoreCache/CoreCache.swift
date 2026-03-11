import Foundation

public enum ReadPlanPart: Equatable, Sendable {
    case file(ByteRange)
    case network(ByteRange)
}

public final class CoreCache: @unchecked Sendable {
    // Single synchronization strategy for mutable CoreCache state.
    // Reads use queue.sync; all mutations use barrier writes.
    private let queue = DispatchQueue(label: "CoreCache.CoreCache", attributes: .concurrent)
    private let diskStore: DiskStore
    private let manifestStore: ManifestStore
    private let diskQuotaBytes: Int64?
    private let logger: any StructuredLogger

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
        try queue.sync {
            guard requested.length > 0 else {
                return []
            }

            guard let record = try manifestStore.load(resourceID: resource) else {
                logger.log(
                    StructuredLogEvent(
                        subsystem: "CoreCache",
                        operation: "plan",
                        metadata: [
                            "cacheKey": resource.cacheKey.rawValue,
                            "kind": resource.kind.rawValue,
                            "parts": "1"
                        ]
                    )
                )
                return [.network(requested)]
            }

            let missingRanges = record.completedRanges.missingSubranges(for: requested)
            let parts = validatedPlanParts(requested: requested, missingRanges: missingRanges)
            logger.log(
                StructuredLogEvent(
                    subsystem: "CoreCache",
                    operation: "plan",
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

    @discardableResult
    public func write(
        _ data: Data,
        resource: ResourceID,
        at offset: Int64,
        contentType: String? = nil,
        expectedLength: Int64? = nil,
        pluginsApplied: [PluginStamp]? = nil
    ) throws -> ByteRange {
        try queue.sync(flags: .barrier) {
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
            try enforceDiskQuotaIfNeeded()
            logger.log(
                StructuredLogEvent(
                    subsystem: "CoreCache",
                    operation: "write",
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
        try queue.sync {
            let data = try diskStore.read(resourceID: resource, range: range)
            logger.log(
                StructuredLogEvent(
                    subsystem: "CoreCache",
                    operation: "read",
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
        try queue.sync(flags: .barrier) {
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
            try enforceDiskQuotaIfNeeded()
            logger.log(
                StructuredLogEvent(
                    subsystem: "CoreCache",
                    operation: "finalizeWrite",
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

    private func enforceDiskQuotaIfNeeded() throws {
        guard let diskQuotaBytes else {
            return
        }

        var entries = manifestStore.allRecords()
        guard !entries.isEmpty else {
            return
        }

        var bytesByResource: [ResourceID: Int64] = [:]
        var totalBytes: Int64 = 0
        for entry in entries {
            let length = try diskStore.fileLength(for: entry.resourceID)
            bytesByResource[entry.resourceID] = length
            totalBytes += length
        }

        guard totalBytes > diskQuotaBytes else {
            return
        }

        entries.sort { lhs, rhs in
            if lhs.record.lastUpdated != rhs.record.lastUpdated {
                return lhs.record.lastUpdated < rhs.record.lastUpdated
            }
            if lhs.resourceID.cacheKey.rawValue != rhs.resourceID.cacheKey.rawValue {
                return lhs.resourceID.cacheKey.rawValue < rhs.resourceID.cacheKey.rawValue
            }
            return lhs.resourceID.resourceKey < rhs.resourceID.resourceKey
        }

        for entry in entries where totalBytes > diskQuotaBytes {
            let resource = entry.resourceID
            let length = bytesByResource[resource] ?? 0

            try diskStore.remove(resourceID: resource)
            try manifestStore.delete(resourceID: resource)
            logger.log(
                StructuredLogEvent(
                    subsystem: "CoreCache",
                    operation: "evict",
                    metadata: [
                        "cacheKey": resource.cacheKey.rawValue,
                        "kind": resource.kind.rawValue,
                        "bytes": String(length)
                    ]
                )
            )

            totalBytes -= length
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
