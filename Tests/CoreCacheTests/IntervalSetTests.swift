import Foundation
import Testing
@testable import CoreCache

private func br(_ start: Int64, _ endExclusive: Int64) throws -> ByteRange {
    try #require(ByteRange(start: start, endExclusive: endExclusive))
}

@Test func intervalSet_insert_mergesAdjacentRanges() throws {
    var set = IntervalSet()
    set.insert(try br(0, 10))
    set.insert(try br(10, 20))

    #expect(set.normalized == [try br(0, 20)])
}

@Test func intervalSet_insert_mergesOverlappingRanges() throws {
    var set = IntervalSet()
    set.insert(try br(0, 10))
    set.insert(try br(5, 15))

    #expect(set.normalized == [try br(0, 15)])
}

@Test func intervalSet_insert_unsortedInput_resultsNormalizedAndSorted() throws {
    var set = IntervalSet()
    set.insert(try br(30, 40))
    set.insert(try br(0, 10))
    set.insert(try br(5, 15))
    set.insert(try br(20, 25))
    set.insert(try br(15, 20))

    #expect(set.normalized == [try br(0, 25), try br(30, 40)])
}

@Test func intervalSet_contains_behavesForFullPartialAndEmptyRanges() throws {
    var set = IntervalSet()
    set.insert(try br(0, 20))

    #expect(set.contains(try br(0, 1)))
    #expect(set.contains(try br(0, 20)))
    #expect(set.contains(try br(5, 10)))
    #expect(!set.contains(try br(19, 21)))
    #expect(set.contains(try br(7, 7)))
}

@Test func intervalSet_missingSubranges_emptySet_returnsRequested() throws {
    let set = IntervalSet()
    let requested = try br(5, 7)

    #expect(set.missingSubranges(for: requested) == [requested])
}

@Test func intervalSet_missingSubranges_fullCoverage_returnsEmpty() throws {
    var set = IntervalSet()
    set.insert(try br(0, 30))

    #expect(set.missingSubranges(for: try br(0, 30)).isEmpty)
}

@Test func intervalSet_missingSubranges_partialCoverage_multipleGaps() throws {
    var set = IntervalSet()
    set.insert(try br(0, 5))
    set.insert(try br(10, 12))
    set.insert(try br(15, 20))

    let missing = set.missingSubranges(for: try br(0, 20))
    #expect(missing == [try br(5, 10), try br(12, 15)])
}

@Test func intervalSet_missingSubranges_handlesEdgeGaps() throws {
    var set = IntervalSet()
    set.insert(try br(10, 20))

    let missing = set.missingSubranges(for: try br(0, 30))
    #expect(missing == [try br(0, 10), try br(20, 30)])
}

@Test func intervalSet_missingSubranges_treatsAdjacencyAsContinuousCoverage() throws {
    var set = IntervalSet()
    set.insert(try br(0, 10))
    set.insert(try br(10, 20))

    #expect(set.missingSubranges(for: try br(0, 20)).isEmpty)
}

@Test func intervalSet_codable_roundTripPreservesData() throws {
    let original = IntervalSet([try br(0, 10), try br(20, 30)])

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(IntervalSet.self, from: data)

    #expect(decoded == original)
}

@Test func intervalSet_codable_decodeNormalizesUnsortedOverlappingPayload() throws {
    let json = """
    [
      {"start": 10, "endExclusive": 20},
      {"start": 0, "endExclusive": 10},
      {"start": 5, "endExclusive": 15}
    ]
    """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(IntervalSet.self, from: json)

    #expect(decoded.normalized == [try br(0, 20)])
}
