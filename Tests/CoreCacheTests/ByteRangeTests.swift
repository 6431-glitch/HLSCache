import Testing
@testable import CoreCache

@Test func cacheKeyFromAssetID_isStableAndHexFormatted() {
    let input = "asset-001"
    let same1 = CacheKey.fromAssetID(input)
    let same2 = CacheKey.fromAssetID(input)
    let different = CacheKey.fromAssetID("asset-002")

    #expect(same1 == same2)
    #expect(same1 != different)
    #expect(same1.rawValue.count == 64)
    #expect(same1.rawValue.allSatisfy { $0.isHexDigit && !$0.isUppercase })
}

@Test func toHTTPHeaderValue_forNormalRange() throws {
    let range = try #require(ByteRange(start: 10, endExclusive: 20))
    #expect(range.toHTTPHeaderValue(totalLength: nil) == "bytes=10-19")
}

@Test func parseHTTPRange_explicitStartEnd() {
    let parsed = ByteRange.parseHTTPRange("bytes=0-9", totalLength: nil)
    #expect(parsed == ByteRange(start: 0, endExclusive: 10))
}

@Test func parseHTTPRange_openEndedWithTotalLength() {
    let parsed = ByteRange.parseHTTPRange("bytes=10-", totalLength: 100)
    #expect(parsed == ByteRange(start: 10, endExclusive: 100))
}

@Test func parseHTTPRange_suffixWithTotalLength() {
    let parsed = ByteRange.parseHTTPRange("bytes=-10", totalLength: 100)
    #expect(parsed == ByteRange(start: 90, endExclusive: 100))
}

@Test func parseHTTPRange_clampsEndBeyondTotalLength() {
    let parsed = ByteRange.parseHTTPRange("bytes=95-200", totalLength: 100)
    #expect(parsed == ByteRange(start: 95, endExclusive: 100))
}

@Test func parseHTTPRange_invalidCases() {
    #expect(ByteRange.parseHTTPRange("bytes=1-0", totalLength: nil) == nil)
    #expect(ByteRange.parseHTTPRange("bytes=a-b", totalLength: nil) == nil)
    #expect(ByteRange.parseHTTPRange("bytes=0-1,2-3", totalLength: nil) == nil)
    #expect(ByteRange.parseHTTPRange("foo", totalLength: nil) == nil)
    #expect(ByteRange.parseHTTPRange("", totalLength: nil) == nil)
    #expect(ByteRange.parseHTTPRange("bytes=-1-2", totalLength: nil) == nil)
    #expect(ByteRange.parseHTTPRange("bytes=-10", totalLength: nil) == nil)
}
