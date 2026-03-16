import CoreCache
import Foundation
import Testing
@testable import HLSCache

@Test func proxyRangeResponse_fullContent_whenRangeHeaderMissing_returns200WithRequiredHeaders() throws {
    let response = try ProxyRangeResponse.make(rangeHeader: nil, totalLength: 2048)

    #expect(response.statusCode == 200)
    #expect(response.isPartialContent == false)
    #expect(response.requestedRange == ByteRange(start: 0, endExclusive: 2048))
    #expect(response.headers["Accept-Ranges"] == "bytes")
    #expect(response.headers["Content-Length"] == "2048")
    #expect(response.headers["Content-Range"] == nil)
}

@Test func proxyRangeResponse_partialContent_explicitRange_returns206WithCorrectBoundaries() throws {
    let response = try ProxyRangeResponse.make(rangeHeader: "bytes=256-767", totalLength: 2048)

    let expectedRange = try #require(ByteRange(start: 256, endExclusive: 768))
    #expect(response.statusCode == 206)
    #expect(response.isPartialContent == true)
    #expect(response.requestedRange == expectedRange)
    #expect(response.headers["Accept-Ranges"] == "bytes")
    #expect(response.headers["Content-Length"] == "512")
    #expect(response.headers["Content-Range"] == "bytes 256-767/2048")
}

@Test func proxyRangeResponse_partialContent_suffixRange_clampsAgainstTotalLength() throws {
    let response = try ProxyRangeResponse.make(rangeHeader: "bytes=-64", totalLength: 500)

    let expectedRange = try #require(ByteRange(start: 436, endExclusive: 500))
    #expect(response.statusCode == 206)
    #expect(response.requestedRange == expectedRange)
    #expect(response.headers["Content-Length"] == "64")
    #expect(response.headers["Content-Range"] == "bytes 436-499/500")
}

@Test func proxyRangeResponse_partialContent_openEndedRange_usesTotalLengthAsEnd() throws {
    let response = try ProxyRangeResponse.make(rangeHeader: "bytes=100-", totalLength: 350)

    let expectedRange = try #require(ByteRange(start: 100, endExclusive: 350))
    #expect(response.statusCode == 206)
    #expect(response.requestedRange == expectedRange)
    #expect(response.headers["Content-Length"] == "250")
    #expect(response.headers["Content-Range"] == "bytes 100-349/350")
}

@Test func proxyRangeResponse_malformedRangeHeader_fallsBackTo200FullContent() throws {
    let response = try ProxyRangeResponse.make(rangeHeader: "bytes=100-50", totalLength: 350)

    #expect(response.statusCode == 200)
    #expect(response.requestedRange == ByteRange(start: 0, endExclusive: 350))
    #expect(response.headers["Accept-Ranges"] == "bytes")
    #expect(response.headers["Content-Length"] == "350")
    #expect(response.headers["Content-Range"] == nil)
}

@Test func proxyRangeResponse_malformedMultiRangeHeader_fallsBackTo200FullContent() throws {
    let response = try ProxyRangeResponse.make(rangeHeader: "bytes=0-10,20-30", totalLength: 350)

    #expect(response.statusCode == 200)
    #expect(response.requestedRange == ByteRange(start: 0, endExclusive: 350))
    #expect(response.headers["Accept-Ranges"] == "bytes")
    #expect(response.headers["Content-Length"] == "350")
    #expect(response.headers["Content-Range"] == nil)
}

@Test func proxyRangeResponse_whitespaceOnlyRangeHeader_fallsBackTo200FullContent() throws {
    let response = try ProxyRangeResponse.make(rangeHeader: "   ", totalLength: 350)

    #expect(response.statusCode == 200)
    #expect(response.requestedRange == ByteRange(start: 0, endExclusive: 350))
    #expect(response.headers["Accept-Ranges"] == "bytes")
    #expect(response.headers["Content-Length"] == "350")
    #expect(response.headers["Content-Range"] == nil)
}

@Test func proxyRangeResponse_unsatisfiableRange_returns416WithRequiredHeaders() throws {
    let response = try ProxyRangeResponse.make(rangeHeader: "bytes=400-500", totalLength: 350)

    #expect(response.statusCode == 416)
    #expect(response.requestedRange == ByteRange(start: 0, endExclusive: 0))
    #expect(response.headers["Accept-Ranges"] == "bytes")
    #expect(response.headers["Content-Length"] == "0")
    #expect(response.headers["Content-Range"] == "bytes */350")
}

@Test func proxyRangeResponse_negativeTotalLength_throws() throws {
    do {
        _ = try ProxyRangeResponse.make(rangeHeader: nil, totalLength: -1)
        #expect(Bool(false))
    } catch let error as ProxyRangeResponseError {
        #expect(error == .invalidTotalLength(-1))
    }
}
