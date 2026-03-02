import Foundation

/// Stores normalized half-open byte ranges (`[start, endExclusive)`).
public struct IntervalSet: Codable, Hashable, Sendable {
    public private(set) var ranges: [ByteRange]

    public init() {
        self.ranges = []
    }

    public init(_ ranges: [ByteRange]) {
        self.ranges = Self.normalized(ranges)
    }

    public var isEmpty: Bool {
        ranges.isEmpty
    }

    public mutating func insert(_ range: ByteRange) {
        ranges = Self.normalized(ranges + [range])
    }

    private static func normalized(_ input: [ByteRange]) -> [ByteRange] {
        guard !input.isEmpty else {
            return []
        }

        let sorted = input.sorted {
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
