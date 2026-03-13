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

    /// Proxy range boundary policy:
    /// - Missing/empty `Range` header -> `200` with full-content range.
    /// - Valid satisfiable `Range` header -> `206` with `Content-Range`.
    /// - Malformed/invalid `Range` header -> treated as no range (`200` full-content).
    /// - Unsatisfiable `Range` header -> `416` with `Content-Range: bytes */<totalLength>`.
    public static func make(rangeHeader: String?, totalLength: Int64) throws -> ProxyRangeResponse {
        guard totalLength >= 0 else {
            throw ProxyRangeResponseError.invalidTotalLength(totalLength)
        }

        let fullRange = ByteRange(start: 0, endExclusive: totalLength)!
        let trimmedHeader = rangeHeader?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedHeader.isEmpty {
            return ProxyRangeResponse(
                statusCode: 200,
                requestedRange: fullRange,
                headers: [
                    "Accept-Ranges": "bytes",
                    "Content-Length": String(fullRange.length)
                ]
            )
        }

        do {
            let byteRange = try ByteRange.parseHTTPRangeValidated(trimmedHeader, totalLength: totalLength)
            return ProxyRangeResponse(
                statusCode: 206,
                requestedRange: byteRange,
                headers: [
                    "Accept-Ranges": "bytes",
                    "Content-Length": String(byteRange.length),
                    "Content-Range": contentRangeHeader(for: byteRange, totalLength: totalLength)
                ]
            )
        } catch let error as HTTPRangeParseError {
            switch error {
            case .rangeNotSatisfiable:
                return ProxyRangeResponse(
                    statusCode: 416,
                    requestedRange: ByteRange(start: 0, endExclusive: 0)!,
                    headers: [
                        "Accept-Ranges": "bytes",
                        "Content-Length": "0",
                        "Content-Range": unsatisfiedContentRangeHeader(totalLength: totalLength)
                    ]
                )
            default:
                return ProxyRangeResponse(
                    statusCode: 200,
                    requestedRange: fullRange,
                    headers: [
                        "Accept-Ranges": "bytes",
                        "Content-Length": String(fullRange.length)
                    ]
                )
            }
        }
    }

    public static func contentRangeHeader(for range: ByteRange, totalLength: Int64) -> String {
        "bytes \(range.start)-\(range.endExclusive - 1)/\(totalLength)"
    }

    public static func unsatisfiedContentRangeHeader(totalLength: Int64) -> String {
        "bytes */\(totalLength)"
    }
}
