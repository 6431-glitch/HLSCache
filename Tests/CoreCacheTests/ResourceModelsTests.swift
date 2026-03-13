import Foundation
import Testing
@testable import CoreCache

@Test func resourceKind_codableRoundTrip() throws {
    let original: ResourceKind = .playlistM3U8
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ResourceKind.self, from: encoded)

    #expect(decoded == original)
}

@Test func resourceID_makeResourceKey_isStableAndCanonicalizedForQueryOrder() throws {
    let url1 = try #require(URL(string: "https://Example.com/media/seg.ts?b=2&a=1"))
    let url2 = try #require(URL(string: "https://example.com/media/seg.ts?a=1&b=2"))
    let url3 = try #require(URL(string: "https://example.com/media/seg.ts?a=1&b=3"))

    let key1 = ResourceID.makeResourceKey(from: url1)
    let key2 = ResourceID.makeResourceKey(from: url1)
    let keyReordered = ResourceID.makeResourceKey(from: url2)
    let keyDifferent = ResourceID.makeResourceKey(from: url3)

    #expect(key1 == key2)
    #expect(key1 == keyReordered)
    #expect(key1 != keyDifferent)
    #expect(key1.count == 64)
    #expect(key1.allSatisfy { $0.isHexDigit && !$0.isUppercase })
}

@Test func resourceID_makeResourceKey_normalizesDefaultPortPathAndEncodingPolicy() throws {
    let variantA = try #require(URL(string: "HTTPS://Example.com:443/a/./b/../c/%7eseg.ts?b=2&a=%7E#frag"))
    let variantB = try #require(URL(string: "https://example.com/a/c/~seg.ts?a=~&b=2"))

    let keyA = ResourceID.makeResourceKey(from: variantA)
    let keyB = ResourceID.makeResourceKey(from: variantB)

    #expect(keyA == keyB)
}

@Test func resourceID_makeResourceKey_queryDuplicateOrderPolicy_preservesRepeatedParamOrder() throws {
    let sameSemanticsA = try #require(URL(string: "https://cdn.example.com/seg.ts?z=9&a=1&a=2"))
    let sameSemanticsB = try #require(URL(string: "https://cdn.example.com/seg.ts?a=1&a=2&z=9"))
    let differentSemantics = try #require(URL(string: "https://cdn.example.com/seg.ts?a=2&a=1&z=9"))

    let keyA = ResourceID.makeResourceKey(from: sameSemanticsA)
    let keyB = ResourceID.makeResourceKey(from: sameSemanticsB)
    let keyDifferent = ResourceID.makeResourceKey(from: differentSemantics)

    #expect(keyA == keyB)
    #expect(keyA != keyDifferent)
}

@Test func resourceID_canonicalURLString_isIdempotent() throws {
    let raw = try #require(URL(string: "https://EXAMPLE.com:443/root/../media/%7Eclip.ts?b=2&a=1&a=2#section"))
    let canonical = ResourceID.canonicalURLString(from: raw)
    let canonicalURL = try #require(URL(string: canonical))
    let canonicalAgain = ResourceID.canonicalURLString(from: canonicalURL)

    #expect(canonical == canonicalAgain)
}

@Test func resourceRecord_codableRoundTrip_preservesFieldsAndCompletedRanges() throws {
    let firstRange = try #require(ByteRange(start: 0, endExclusive: 10))
    let secondRange = try #require(ByteRange(start: 20, endExclusive: 30))

    let intervalSet = IntervalSet([firstRange, secondRange])
    let stamp = PluginStamp(id: "playlist-rewrite", version: "1.0.0")
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    let original = ResourceRecord(
        kind: .segment,
        originalURL: URL(string: "https://cdn.example.com/video/segment.ts")!,
        contentType: "video/mp2t",
        expectedLength: 4096,
        completedRanges: intervalSet,
        pluginsApplied: [stamp],
        lastUpdated: date
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ResourceRecord.self, from: data)

    #expect(decoded.kind == original.kind)
    #expect(decoded.originalURL == original.originalURL)
    #expect(decoded.contentType == original.contentType)
    #expect(decoded.expectedLength == original.expectedLength)
    #expect(decoded.completedRanges == original.completedRanges)
    #expect(decoded.pluginsApplied == original.pluginsApplied)
    #expect(decoded.lastUpdated == original.lastUpdated)
}

@Test func resourceRecord_validateInvariants_expectedLengthBoundaryPasses() throws {
    var ranges = IntervalSet()
    ranges.insert(try #require(ByteRange(start: 0, endExclusive: 32)))

    let record = ResourceRecord(
        kind: .segment,
        expectedLength: 32,
        completedRanges: ranges
    )

    try record.validateInvariants()
}

@Test func resourceRecord_validateInvariants_completedRangeExceedsExpectedLengthFails() throws {
    var ranges = IntervalSet()
    ranges.insert(try #require(ByteRange(start: 0, endExclusive: 33)))

    let record = ResourceRecord(
        kind: .segment,
        expectedLength: 32,
        completedRanges: ranges
    )

    do {
        try record.validateInvariants()
        #expect(Bool(false))
    } catch let error as ResourceRecordInvariantError {
        #expect(error == .completedRangeExceedsExpectedLength(expectedLength: 32, actualEndExclusive: 33))
    }
}
