import Foundation

/// Stores normalized half-open byte ranges (`[start, endExclusive)`).
public struct IntervalSet: Codable, Hashable, Sendable {
    private var ranges: [ByteRange]

    public init() {
        self.ranges = []
    }

    public init(_ ranges: [ByteRange]) {
        self.ranges = Self.normalize(ranges)
    }

    public var isEmpty: Bool {
        ranges.isEmpty
    }

    /// Always returns sorted, non-overlapping half-open ranges.
    public var normalized: [ByteRange] {
        ranges
    }

    public mutating func insert(_ range: ByteRange) {
        guard range.length > 0 else {
            return
        }
        ranges = Self.normalize(ranges + [range])
    }

    /// Returns true only if the full half-open `range` is covered by existing intervals.
    /// Empty ranges are considered contained.
    public func contains(_ range: ByteRange) -> Bool {
        if range.length == 0 {
            return true
        }

        var cursor = range.start
        for covered in ranges {
            if covered.endExclusive <= cursor {
                continue
            }

            if covered.start > cursor {
                return false
            }

            cursor = max(cursor, covered.endExclusive)
            if cursor >= range.endExclusive {
                return true
            }
        }

        return cursor >= range.endExclusive
    }

    /// Returns normalized gaps within `requested` that are not covered by stored intervals.
    public func missingSubranges(for requested: ByteRange) -> [ByteRange] {
        if requested.length == 0 {
            return []
        }

        var missing: [ByteRange] = []
        var cursor = requested.start

        for covered in ranges {
            if covered.endExclusive <= cursor {
                continue
            }

            if covered.start >= requested.endExclusive {
                break
            }

            if covered.start > cursor {
                let gapEnd = min(covered.start, requested.endExclusive)
                if gapEnd > cursor {
                    missing.append(ByteRange(start: cursor, endExclusive: gapEnd)!)
                }
            }

            cursor = max(cursor, covered.endExclusive)
            if cursor >= requested.endExclusive {
                break
            }
        }

        if cursor < requested.endExclusive {
            missing.append(ByteRange(start: cursor, endExclusive: requested.endExclusive)!)
        }

        return missing
    }

    public func intersects(_ range: ByteRange) -> Bool {
        if range.length == 0 {
            return false
        }

        for covered in ranges {
            if covered.endExclusive <= range.start {
                continue
            }
            if covered.start >= range.endExclusive {
                return false
            }
            return true
        }
        return false
    }

    public func totalCoveredLength() -> Int64 {
        ranges.reduce(0) { $0 + $1.length }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decodedRanges = try container.decode([ByteRange].self)
        self.ranges = Self.normalize(decodedRanges)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ranges)
    }

    private static func normalize(_ input: [ByteRange]) -> [ByteRange] {
        let nonEmpty = input.filter { $0.length > 0 }
        guard !nonEmpty.isEmpty else {
            return []
        }

        let sorted = nonEmpty.sorted {
            if $0.start != $1.start {
                return $0.start < $1.start
            }
            return $0.endExclusive < $1.endExclusive
        }

        var result: [ByteRange] = []
        result.reserveCapacity(sorted.count)

        for range in sorted {
            guard let last = result.last else {
                result.append(range)
                continue
            }

            // Adjacent (`==`) ranges are merged to maintain continuous coverage.
            if range.start <= last.endExclusive {
                let mergedEnd = max(last.endExclusive, range.endExclusive)
                result[result.count - 1] = ByteRange(start: last.start, endExclusive: mergedEnd)!
            } else {
                result.append(range)
            }
        }

        return result
    }
}
