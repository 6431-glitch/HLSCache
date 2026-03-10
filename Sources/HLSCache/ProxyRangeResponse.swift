import CoreCache
import Foundation

public enum ProxyRangeResponseError: Error, Equatable, Sendable {
    case invalidTotalLength(Int64)
    case invalidRangeHeader(String)
}

public struct ProxyRangeResponse: Equatable, Sendable {
    public let statusCode: Int
    public let requestedRange: ByteRange
    public let headers: [String: String]

    public init(statusCode: Int, requestedRange: ByteRange, headers: [String: String]) {
        self.statusCode = statusCode
        self.requestedRange = requestedRange
        self.headers = headers
    }

    public var isPartialContent: Bool {
        statusCode == 206
    }

    public static func make(rangeHeader: String?, totalLength: Int64) throws -> ProxyRangeResponse {
        guard totalLength >= 0 else {
            throw ProxyRangeResponseError.invalidTotalLength(totalLength)
        }

        let trimmedHeader = rangeHeader?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedHeader.isEmpty {
            let fullRange = ByteRange(start: 0, endExclusive: totalLength)!
            return ProxyRangeResponse(
                statusCode: 200,
                requestedRange: fullRange,
                headers: [
                    "Accept-Ranges": "bytes",
                    "Content-Length": String(fullRange.length)
                ]
            )
        }

        guard let byteRange = ByteRange.parseHTTPRange(trimmedHeader, totalLength: totalLength) else {
            throw ProxyRangeResponseError.invalidRangeHeader(trimmedHeader)
        }

        return ProxyRangeResponse(
            statusCode: 206,
            requestedRange: byteRange,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": String(byteRange.length),
                "Content-Range": contentRangeHeader(for: byteRange, totalLength: totalLength)
            ]
        )
    }

    public static func contentRangeHeader(for range: ByteRange, totalLength: Int64) -> String {
        "bytes \(range.start)-\(range.endExclusive - 1)/\(totalLength)"
    }
}
