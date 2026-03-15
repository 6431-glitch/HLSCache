import Foundation

public enum ResourceRecordInvariantError: Error, Equatable, Sendable {
    case invalidExpectedLength(Int64)
    case completedRangeExceedsExpectedLength(expectedLength: Int64, actualEndExclusive: Int64)
}

public enum ResourceKind: String, Codable, Hashable, Sendable {
    case playlistM3U8
    case segment
    case key
    case other
}

public struct PluginStamp: Codable, Hashable, Sendable {
    public let id: String
    public let version: String

    public init(id: String, version: String) {
        self.id = id
        self.version = version
    }
}

public struct ResourceIntegrity: Codable, Hashable, Sendable {
    public let algorithm: String
    public let digestHex: String

    public init(algorithm: String, digestHex: String) {
        self.algorithm = algorithm
        self.digestHex = digestHex
    }
}

public struct ResourceID: Codable, Hashable, Sendable {
    public let cacheKey: CacheKey
    public let kind: ResourceKind
    public let resourceKey: String

    public init(cacheKey: CacheKey, kind: ResourceKind, resourceKey: String) {
        self.cacheKey = cacheKey
        self.kind = kind
        self.resourceKey = resourceKey
    }

    public static func makeResourceKey(from url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return makeResourceKey(from: url.absoluteString)
        }

        return makeResourceKey(
            from: canonicalURLString(
                from: &components,
                fallback: url.absoluteString,
                queryNormalization: .sortedByName
            )
        )
    }

    public static func canonicalURLString(from url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        return canonicalURLString(
            from: &components,
            fallback: url.absoluteString,
            queryNormalization: .sortedByName
        )
    }

    public static func makeLegacyResourceKeyCandidates(from url: URL) -> [String] {
        let primaryKey = makeResourceKey(from: url)
        var candidates: [String] = []

        let directLegacyKey = makeResourceKey(from: url.absoluteString)
        if directLegacyKey != primaryKey {
            candidates.append(directLegacyKey)
        }

        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let legacyCanonical = canonicalURLString(
                from: &components,
                fallback: url.absoluteString,
                queryNormalization: .preserveOrder
            )
            let preservedQueryOrderKey = makeResourceKey(from: legacyCanonical)
            if preservedQueryOrderKey != primaryKey,
               !candidates.contains(preservedQueryOrderKey) {
                candidates.append(preservedQueryOrderKey)
            }
        }

        return candidates
    }

    public static func makeResourceKey(from canonical: String) -> String {
        SHA256Hex.digest(Data(canonical.utf8))
    }

    private enum QueryNormalization {
        case sortedByName
        case preserveOrder
    }

    private static func canonicalURLString(
        from components: inout URLComponents,
        fallback: String,
        queryNormalization: QueryNormalization
    ) -> String {
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil

        if let scheme = components.scheme?.lowercased(),
           let port = components.port,
           defaultPort(for: scheme) == port {
            components.port = nil
        }

        components.percentEncodedPath = normalizePath(components.percentEncodedPath)
        switch queryNormalization {
        case .sortedByName:
            components.percentEncodedQuery = normalizeQuery(components.percentEncodedQuery)
        case .preserveOrder:
            components.percentEncodedQuery = normalizeQueryPreservingOrder(components.percentEncodedQuery)
        }

        return components.string ?? fallback
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }

    private static func normalizePath(_ path: String) -> String {
        guard !path.isEmpty else {
            return "/"
        }

        let hasLeadingSlash = path.hasPrefix("/")
        let hasTrailingSlash = path.hasSuffix("/") && path != "/"
        let rawSegments = path.split(separator: "/", omittingEmptySubsequences: true)

        var normalizedSegments: [String] = []
        normalizedSegments.reserveCapacity(rawSegments.count)

        for segment in rawSegments {
            let normalizedSegment = normalizePercentEncoding(String(segment))
            let decoded = normalizedSegment.removingPercentEncoding ?? normalizedSegment

            if decoded == "." {
                continue
            }
            if decoded == ".." {
                if !normalizedSegments.isEmpty {
                    _ = normalizedSegments.removeLast()
                }
                continue
            }

            normalizedSegments.append(normalizedSegment)
        }

        var normalizedPath = hasLeadingSlash ? "/" : ""
        normalizedPath += normalizedSegments.joined(separator: "/")
        if normalizedPath.isEmpty {
            normalizedPath = "/"
        }
        if hasTrailingSlash && normalizedPath != "/" {
            normalizedPath += "/"
        }

        return normalizedPath
    }

    private static func normalizeQuery(_ percentEncodedQuery: String?) -> String? {
        guard let percentEncodedQuery else {
            return nil
        }

        let parts = percentEncodedQuery.split(separator: "&", omittingEmptySubsequences: false)
        if parts.isEmpty {
            return percentEncodedQuery
        }

        struct QueryPart {
            let name: String
            let value: String?
            let hasEquals: Bool
            let index: Int
        }

        let parsed: [QueryPart] = parts.enumerated().map { index, rawPart in
            let part = String(rawPart)
            if let equalsIndex = part.firstIndex(of: "=") {
                let rawName = String(part[..<equalsIndex])
                let rawValue = String(part[part.index(after: equalsIndex)...])
                return QueryPart(
                    name: normalizePercentEncoding(rawName),
                    value: normalizePercentEncoding(rawValue),
                    hasEquals: true,
                    index: index
                )
            }

            return QueryPart(
                name: normalizePercentEncoding(part),
                value: nil,
                hasEquals: false,
                index: index
            )
        }

        let sorted = parsed.sorted { lhs, rhs in
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            return lhs.index < rhs.index
        }

        return sorted.map { part in
            if part.hasEquals {
                return "\(part.name)=\(part.value ?? "")"
            }
            return part.name
        }
        .joined(separator: "&")
    }

    private static func normalizeQueryPreservingOrder(_ percentEncodedQuery: String?) -> String? {
        guard let percentEncodedQuery else {
            return nil
        }

        let parts = percentEncodedQuery.split(separator: "&", omittingEmptySubsequences: false)
        if parts.isEmpty {
            return percentEncodedQuery
        }

        return parts.map { rawPart in
            let part = String(rawPart)
            if let equalsIndex = part.firstIndex(of: "=") {
                let rawName = String(part[..<equalsIndex])
                let rawValue = String(part[part.index(after: equalsIndex)...])
                let normalizedName = normalizePercentEncoding(rawName)
                let normalizedValue = normalizePercentEncoding(rawValue)
                return "\(normalizedName)=\(normalizedValue)"
            }

            return normalizePercentEncoding(part)
        }
        .joined(separator: "&")
    }

    private static func normalizePercentEncoding(_ raw: String) -> String {
        guard raw.contains("%") else {
            return raw
        }

        let scalars = Array(raw.unicodeScalars)
        var output = String.UnicodeScalarView()
        output.reserveCapacity(scalars.count)

        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "%",
               index + 2 < scalars.count,
               let hi = hexValue(of: scalars[index + 1]),
               let lo = hexValue(of: scalars[index + 2]) {
                let value = UInt8(hi * 16 + lo)
                if let decodedScalar = UnicodeScalar(Int(value)), isUnreserved(decodedScalar) {
                    output.append(decodedScalar)
                } else {
                    output.append("%")
                    output.append(upperHexScalar(for: hi))
                    output.append(upperHexScalar(for: lo))
                }
                index += 3
                continue
            }

            output.append(scalar)
            index += 1
        }

        return String(output)
    }

    private static func hexValue(of scalar: UnicodeScalar) -> Int? {
        switch scalar.value {
        case 48...57: // 0-9
            return Int(scalar.value - 48)
        case 65...70: // A-F
            return Int(scalar.value - 55)
        case 97...102: // a-f
            return Int(scalar.value - 87)
        default:
            return nil
        }
    }

    private static func upperHexScalar(for value: Int) -> UnicodeScalar {
        precondition((0...15).contains(value))
        if value < 10 {
            return UnicodeScalar(48 + value)!
        }
        return UnicodeScalar(55 + value)!
    }

    private static func isUnreserved(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122, 45, 46, 95, 126:
            return true
        default:
            return false
        }
    }
}

public struct ResourceRecord: Codable, Hashable, Sendable {
    public let kind: ResourceKind
    public var originalURL: URL?
    public var contentType: String?
    public var expectedLength: Int64?
    public var completedRanges: IntervalSet
    public var pluginsApplied: [PluginStamp]
    public var integrity: ResourceIntegrity?
    public var lastUpdated: Date

    public init(
        kind: ResourceKind,
        originalURL: URL? = nil,
        contentType: String? = nil,
        expectedLength: Int64? = nil,
        completedRanges: IntervalSet = .init(),
        pluginsApplied: [PluginStamp] = [],
        integrity: ResourceIntegrity? = nil,
        lastUpdated: Date = Date()
    ) {
        self.kind = kind
        self.originalURL = originalURL
        self.contentType = contentType
        self.expectedLength = expectedLength
        self.completedRanges = completedRanges
        self.pluginsApplied = pluginsApplied
        self.integrity = integrity
        self.lastUpdated = lastUpdated
    }

    public mutating func touch(_ date: Date = Date()) {
        lastUpdated = date
    }

    public func validateInvariants() throws {
        guard let expectedLength else {
            return
        }

        guard expectedLength >= 0 else {
            throw ResourceRecordInvariantError.invalidExpectedLength(expectedLength)
        }

        let actualEndExclusive = completedRanges.normalized.last?.endExclusive ?? 0
        guard actualEndExclusive <= expectedLength else {
            throw ResourceRecordInvariantError.completedRangeExceedsExpectedLength(
                expectedLength: expectedLength,
                actualEndExclusive: actualEndExclusive
            )
        }
    }
}
