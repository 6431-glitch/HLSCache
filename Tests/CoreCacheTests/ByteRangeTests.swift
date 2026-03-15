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

@Test func parseHTTPRangeValidated_validInput_matchesOptionalParserBehavior() throws {
    let strict = try ByteRange.parseHTTPRangeValidated("bytes=95-200", totalLength: 100)
    let optional = ByteRange.parseHTTPRange("bytes=95-200", totalLength: 100)
    #expect(strict == ByteRange(start: 95, endExclusive: 100))
    #expect(optional == strict)
}

@Test func parseHTTPRangeValidated_overflowOnInclusiveEnd_throwsTypedError() {
    do {
        _ = try ByteRange.parseHTTPRangeValidated("bytes=0-9223372036854775807", totalLength: nil)
        #expect(Bool(false))
    } catch let error as HTTPRangeParseError {
        #expect(error == .overflow)
    } catch {
        #expect(Bool(false))
    }
}

@Test func parseHTTPRangeValidated_extremeMalformedValues_throwsDeterministicErrors() {
    do {
        _ = try ByteRange.parseHTTPRangeValidated("bytes=0-999999999999999999999999999999", totalLength: nil)
        #expect(Bool(false))
    } catch let error as HTTPRangeParseError {
        #expect(error == .invalidEnd)
    } catch {
        #expect(Bool(false))
    }

    do {
        _ = try ByteRange.parseHTTPRangeValidated("bytes=10-", totalLength: nil)
        #expect(Bool(false))
    } catch let error as HTTPRangeParseError {
        #expect(error == .missingTotalLength)
    } catch {
        #expect(Bool(false))
    }
}

@Test func parseHTTPRangeValidated_malformedHeaderCorpus_isDeterministicAndTyped() {
    let headers = malformedHTTPRangeHeaderCorpus()
    let totalLengths: [Int64?] = [nil, 1, 128, 1024]

    for totalLength in totalLengths {
        for header in headers {
            let first = strictParseOutcome(for: header, totalLength: totalLength)
            let second = strictParseOutcome(for: header, totalLength: totalLength)

            #expect(first == second)

            switch first {
            case .parsed(let range):
                #expect(ByteRange.parseHTTPRange(header, totalLength: totalLength) == range)
                #expect(range.length > 0)
                if let totalLength {
                    #expect(range.endExclusive <= totalLength)
                }
            case .failed:
                #expect(ByteRange.parseHTTPRange(header, totalLength: totalLength) == nil)
            case .unexpectedError:
                #expect(Bool(false))
            }
        }
    }
}

private enum StrictRangeParseOutcome: Equatable {
    case parsed(ByteRange)
    case failed(HTTPRangeParseError)
    case unexpectedError
}

private func strictParseOutcome(for header: String, totalLength: Int64?) -> StrictRangeParseOutcome {
    do {
        return .parsed(try ByteRange.parseHTTPRangeValidated(header, totalLength: totalLength))
    } catch let error as HTTPRangeParseError {
        return .failed(error)
    } catch {
        return .unexpectedError
    }
}

private func malformedHTTPRangeHeaderCorpus() -> [String] {
    var headers: Set<String> = [
        "",
        " ",
        "\t",
        "foo",
        "bytes",
        "bytes=",
        "bytes=-",
        "bytes=--",
        "bytes=0--1",
        "bytes=0-1-2",
        "bytes=1",
        "bytes=1,2",
        "bytes=0-1,2-3",
        "bytes=+1-2",
        "bytes=1-+2",
        "bytes=-0",
        "bytes=-9223372036854775808",
        "bytes=9223372036854775808-9223372036854775809",
        "bytes=0-9223372036854775807",
        "bytes=0-999999999999999999999999999999",
        "bytes=999999999999999999999999999999-0",
        "bytes=01-00",
        "bytes=10-9",
        "bytes=\t0-\t1",
        "bytes=0 - 1",
        "bytes =0-1",
        "bytes :0-1",
        "items=0-1",
        "octets=0-1"
    ]

    headers.formUnion(generatedMalformedHeaders(seed: 1_700, count: 320))
    return headers.sorted()
}

private func generatedMalformedHeaders(seed: UInt64, count: Int) -> [String] {
    var rng = DeterministicRangeRNG(state: seed)
    var generated: Set<String> = []

    let units = [
        "",
        "bytes=",
        "BYTES=",
        "bytes =",
        "bytes:",
        "items=",
        "octets=",
        "bytes=="
    ]
    let separators = ["-", "--", "---", "", " - ", "\t-\t", ":-", "-:", ",", ".-."]
    let tokens = [
        "",
        "0",
        "1",
        "9",
        "10",
        "0001",
        "-1",
        "+1",
        "a",
        "1a",
        "9223372036854775807",
        "9223372036854775808",
        "18446744073709551615",
        "999999999999999999999999999999",
        String(repeating: "9", count: 96)
    ]
    let suffixes = ["", ",1-2", ",", ",,", " extra", " ;", " /", "\t", "\n"]
    let paddings = ["", " ", "\t", "  ", "\n", "\r\n"]

    while generated.count < count {
        let header =
            "\(rng.pick(paddings))\(rng.pick(units))\(rng.pick(tokens))\(rng.pick(separators))\(rng.pick(tokens))\(rng.pick(suffixes))\(rng.pick(paddings))"
        generated.insert(header)
    }

    return generated.sorted()
}

private struct DeterministicRangeRNG {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    mutating func pick<T>(_ values: [T]) -> T {
        values[Int(next() % UInt64(values.count))]
    }
}
