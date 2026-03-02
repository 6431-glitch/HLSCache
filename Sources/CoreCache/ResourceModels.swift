import Foundation

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

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()

        if let queryItems = components.queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems.sorted { lhs, rhs in
                if lhs.name != rhs.name {
                    return lhs.name < rhs.name
                }
                return (lhs.value ?? "") < (rhs.value ?? "")
            }
        }

        let canonical = components.string ?? url.absoluteString
        return makeResourceKey(from: canonical)
    }

    public static func makeResourceKey(from canonical: String) -> String {
        SHA256Hex.digest(Data(canonical.utf8))
    }
}

public struct ResourceRecord: Codable, Hashable, Sendable {
    public let kind: ResourceKind
    public var originalURL: URL?
    public var contentType: String?
    public var expectedLength: Int64?
    public var completedRanges: IntervalSet
    public var pluginsApplied: [PluginStamp]
    public var lastUpdated: Date

    public init(
        kind: ResourceKind,
        originalURL: URL? = nil,
        contentType: String? = nil,
        expectedLength: Int64? = nil,
        completedRanges: IntervalSet = .init(),
        pluginsApplied: [PluginStamp] = [],
        lastUpdated: Date = Date()
    ) {
        self.kind = kind
        self.originalURL = originalURL
        self.contentType = contentType
        self.expectedLength = expectedLength
        self.completedRanges = completedRanges
        self.pluginsApplied = pluginsApplied
        self.lastUpdated = lastUpdated
    }

    public mutating func touch(_ date: Date = Date()) {
        lastUpdated = date
    }
}
