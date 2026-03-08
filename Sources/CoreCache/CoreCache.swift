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

    public init(baseDirectory: URL) {
        self.diskStore = DiskStore(baseDirectory: baseDirectory)
        self.manifestStore = ManifestStore(baseDirectory: baseDirectory)
    }

    public func plan(resource: ResourceID, requested: ByteRange) throws -> [ReadPlanPart] {
        try queue.sync {
            guard requested.length > 0 else {
                return []
            }

            guard let record = try manifestStore.load(resourceID: resource) else {
                return [.network(requested)]
            }

            let missingRanges = record.completedRanges.missingSubranges(for: requested)
            return validatedPlanParts(requested: requested, missingRanges: missingRanges)
        }
    }

    @discardableResult
    public func write(
        _ data: Data,
        resource: ResourceID,
        at offset: Int64,
        contentType: String? = nil,
        expectedLength: Int64? = nil
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

            record.touch()
            try manifestStore.save(resourceID: resource, record: record)
            return writtenRange
        }
    }

    @discardableResult
    public func finalizeWrite(resource: ResourceID, expectedLength: Int64? = nil) throws -> ResourceRecord {
        try queue.sync(flags: .barrier) {
            var record = try manifestStore.load(resourceID: resource) ?? ResourceRecord(kind: resource.kind)

            if let expectedLength {
                record.expectedLength = expectedLength
            } else if record.expectedLength == nil {
                record.expectedLength = try diskStore.fileLength(for: resource)
            }

            record.touch()
            try manifestStore.save(resourceID: resource, record: record)
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
