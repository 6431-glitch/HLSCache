import CoreCache
import Foundation

public protocol HLSCachePlugin: Sendable {
    var id: String { get }
    var version: String { get }
}

public struct CacheInfo: Sendable, Equatable {
    public let alias: Alias
    public let assetID: AssetID
    public let cacheKey: CacheKey
    public let currentRemoteURL: URL
    public let totalBytesOnDisk: Int64
    public let activePluginCount: Int
}

public enum HLSCacheError: Error, Equatable, Sendable {
    case serverNotRunning
    case aliasNotFound(Alias)
}

public final class HLSCacheFacade: @unchecked Sendable {
    private let fileManager: FileManager
    private let baseDirectory: URL
    private let aliasRegistry: AliasRegistry
    private let logger: any StructuredLogger
    private let queue = DispatchQueue(label: "HLSCache.Facade", attributes: .concurrent)

    private var serverBaseURL: URL?
    private var plugins: [any HLSCachePlugin] = []

    public init(baseDirectory: URL, logger: any StructuredLogger = NoopStructuredLogger()) {
        self.fileManager = .default
        self.baseDirectory = baseDirectory
        self.aliasRegistry = AliasRegistry(baseDirectory: baseDirectory)
        self.logger = logger
    }

    @discardableResult
    public func startServer(host: String = "127.0.0.1", port: Int = 8080) -> URL {
        let correlationID = UUID().uuidString
        return queue.sync(flags: .barrier) {
            if let existing = serverBaseURL {
                return existing
            }

            let resolvedPort = port == 0 ? 8080 : port
            let resolvedURL = URL(string: "http://\(host):\(resolvedPort)")!
            serverBaseURL = resolvedURL
            logger.log(
                StructuredLogEvent(
                    subsystem: "HLSCache",
                    operation: "startServer",
                    level: .info,
                    correlationID: correlationID,
                    metadata: ["host": host, "port": String(resolvedPort)]
                )
            )
            return resolvedURL
        }
    }

    public func stopServer() {
        let correlationID = UUID().uuidString
        queue.sync(flags: .barrier) {
            serverBaseURL = nil
            logger.log(
                StructuredLogEvent(
                    subsystem: "HLSCache",
                    operation: "stopServer",
                    level: .info,
                    correlationID: correlationID
                )
            )
        }
    }

    @discardableResult
    public func register(
        alias: Alias,
        assetID: AssetID,
        remoteURL: URL,
        headers: [String: String]? = nil
    ) throws -> AssetRecord {
        let correlationID = UUID().uuidString
        let record = try aliasRegistry.register(alias: alias, assetID: assetID, remoteURL: remoteURL, headers: headers)
        logger.log(
            StructuredLogEvent(
                subsystem: "HLSCache",
                operation: "register",
                level: .info,
                correlationID: correlationID,
                metadata: ["alias": alias, "assetID": assetID]
            )
        )
        return record
    }

    @discardableResult
    public func updateRemoteURL(alias: Alias, remoteURL: URL) throws -> AssetRecord {
        let correlationID = UUID().uuidString
        let updated = try aliasRegistry.updateRemoteURL(alias: alias, remoteURL: remoteURL)
        logger.log(
            StructuredLogEvent(
                subsystem: "HLSCache",
                operation: "updateRemoteURL",
                level: .info,
                correlationID: correlationID,
                metadata: ["alias": alias]
            )
        )
        return updated
    }

    public func listAliases() -> [AssetRecord] {
        let correlationID = UUID().uuidString
        let records = aliasRegistry.allRecords()
        logger.log(
            StructuredLogEvent(
                subsystem: "HLSCache",
                operation: "listAliases",
                level: .debug,
                correlationID: correlationID,
                metadata: ["count": String(records.count)]
            )
        )
        return records
    }

    public func proxyURL(for alias: Alias) throws -> URL {
        let correlationID = UUID().uuidString
        let base = queue.sync { serverBaseURL }
        guard let base else {
            throw HLSCacheError.serverNotRunning
        }

        guard aliasRegistry.resolve(alias: alias) != nil else {
            throw HLSCacheError.aliasNotFound(alias)
        }

        let encodedAlias = alias.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? alias
        logger.log(
            StructuredLogEvent(
                subsystem: "HLSCache",
                operation: "proxyURL",
                level: .debug,
                correlationID: correlationID,
                metadata: ["alias": alias]
            )
        )
        return base.appendingPathComponent(encodedAlias)
    }

    public func proxyURL(for alias: Alias, kind: ProxyResourceKind, remoteURL: URL) throws -> URL {
        let correlationID = UUID().uuidString
        let base = queue.sync { serverBaseURL }
        guard let base else {
            throw HLSCacheError.serverNotRunning
        }

        guard aliasRegistry.resolve(alias: alias) != nil else {
            throw HLSCacheError.aliasNotFound(alias)
        }

        let route = ProxyRoute(alias: alias, kind: kind, remoteURL: remoteURL)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw ProxyRouteError.invalidEncodedURL(base.absoluteString)
        }

        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let routePath = try [
            route.encodedAlias(),
            kind.rawValue,
            route.encodedRemoteURL()
        ].joined(separator: "/")

        if basePath.isEmpty {
            components.percentEncodedPath = "/" + routePath
        } else {
            components.percentEncodedPath = "/" + basePath + "/" + routePath
        }

        guard let url = components.url else {
            throw ProxyRouteError.invalidEncodedURL(remoteURL.absoluteString)
        }

        logger.log(
            StructuredLogEvent(
                subsystem: "HLSCache",
                operation: "proxyURLResource",
                level: .debug,
                correlationID: correlationID,
                metadata: ["alias": alias, "kind": kind.rawValue]
            )
        )
        return url
    }

    public func decodeProxyRequestURL(_ requestURL: URL) throws -> ProxyRoute {
        let correlationID = UUID().uuidString
        let route = try ProxyRoute.from(url: requestURL)
        guard aliasRegistry.resolve(alias: route.alias) != nil else {
            throw HLSCacheError.aliasNotFound(route.alias)
        }
        logger.log(
            StructuredLogEvent(
                subsystem: "HLSCache",
                operation: "decodeProxyRequestURL",
                level: .debug,
                correlationID: correlationID,
                metadata: ["alias": route.alias, "kind": route.kind.rawValue]
            )
        )
        return route
    }

    public func cacheInfo(alias: Alias) throws -> CacheInfo {
        let correlationID = UUID().uuidString
        guard let record = aliasRegistry.resolve(alias: alias) else {
            throw HLSCacheError.aliasNotFound(alias)
        }

        let pluginCount = queue.sync { plugins.count }
        let bytes = directorySize(at: cacheDirectory(for: record.cacheKey))
        logger.log(
            StructuredLogEvent(
                subsystem: "HLSCache",
                operation: "cacheInfo",
                level: .debug,
                correlationID: correlationID,
                metadata: ["alias": alias, "bytes": String(bytes)]
            )
        )

        return CacheInfo(
            alias: record.alias,
            assetID: record.assetID,
            cacheKey: record.cacheKey,
            currentRemoteURL: record.currentRemoteURL,
            totalBytesOnDisk: bytes,
            activePluginCount: pluginCount
        )
    }

    public func clearCache(alias: Alias? = nil) throws {
        let correlationID = UUID().uuidString
        try queue.sync(flags: .barrier) {
            if let alias {
                guard let record = aliasRegistry.resolve(alias: alias) else {
                    throw HLSCacheError.aliasNotFound(alias)
                }
                try removeDirectoryIfPresent(at: cacheDirectory(for: record.cacheKey))
                logger.log(
                    StructuredLogEvent(
                        subsystem: "HLSCache",
                        operation: "clearCache",
                        level: .warning,
                        correlationID: correlationID,
                        metadata: ["alias": alias]
                    )
                )
                return
            }

            try removeDirectoryIfPresent(at: baseDirectory.appendingPathComponent("cache", isDirectory: true))
            logger.log(
                StructuredLogEvent(
                    subsystem: "HLSCache",
                    operation: "clearCache",
                    level: .warning,
                    correlationID: correlationID,
                    metadata: ["alias": "all"]
                )
            )
        }
    }

    @discardableResult
    public func removeAlias(alias: Alias) throws -> AssetRecord {
        let correlationID = UUID().uuidString
        do {
            let removed = try aliasRegistry.unregister(alias: alias)
            logger.log(
                StructuredLogEvent(
                    subsystem: "HLSCache",
                    operation: "removeAlias",
                    level: .warning,
                    correlationID: correlationID,
                    metadata: ["alias": alias]
                )
            )
            return removed
        } catch let error as AliasRegistryError {
            switch error {
            case let .aliasNotFound(missingAlias):
                throw HLSCacheError.aliasNotFound(missingAlias)
            }
        }
    }

    @discardableResult
    public func removeAllAliases() throws -> Int {
        let correlationID = UUID().uuidString
        let removedCount = try aliasRegistry.unregisterAll()
        logger.log(
            StructuredLogEvent(
                subsystem: "HLSCache",
                operation: "removeAllAliases",
                level: .warning,
                correlationID: correlationID,
                metadata: ["count": String(removedCount)]
            )
        )
        return removedCount
    }

    @discardableResult
    public func setPlugins(_ plugins: [any HLSCachePlugin]) -> [PluginStamp] {
        let correlationID = UUID().uuidString
        return queue.sync(flags: .barrier) {
            self.plugins = plugins
            let pluginStamps = plugins.map { PluginStamp(id: $0.id, version: $0.version) }
            logger.log(
                StructuredLogEvent(
                    subsystem: "HLSCache",
                    operation: "setPlugins",
                    level: .info,
                    correlationID: correlationID,
                    metadata: ["count": String(pluginStamps.count)]
                )
            )
            return pluginStamps
        }
    }

    public func activePlugins() -> [PluginStamp] {
        queue.sync {
            plugins.map { PluginStamp(id: $0.id, version: $0.version) }
        }
    }

    public func makeTransformPipeline() -> TransformPipeline {
        queue.sync {
            let transformers = plugins.compactMap { $0 as? any ByteTransformer }
            return TransformPipeline(transformers: transformers)
        }
    }

    private func cacheDirectory(for cacheKey: CacheKey) -> URL {
        baseDirectory
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent(cacheKey.rawValue, isDirectory: true)
    }

    private func removeDirectoryIfPresent(at directory: URL) throws {
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }
        try fileManager.removeItem(at: directory)
    }

    private func directorySize(at directory: URL) -> Int64 {
        guard fileManager.fileExists(atPath: directory.path) else {
            return 0
        }

        var total: Int64 = 0
        if let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true else {
                    continue
                }
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}

private let sharedFacade = HLSCacheFacade(baseDirectory: defaultBaseDirectory())

public func startServer(host: String = "127.0.0.1", port: Int = 8080) -> URL {
    sharedFacade.startServer(host: host, port: port)
}

public func stopServer() {
    sharedFacade.stopServer()
}

@discardableResult
public func register(
    alias: Alias,
    assetID: AssetID,
    remoteURL: URL,
    headers: [String: String]? = nil
) throws -> AssetRecord {
    try sharedFacade.register(alias: alias, assetID: assetID, remoteURL: remoteURL, headers: headers)
}

@discardableResult
public func updateRemoteURL(alias: Alias, remoteURL: URL) throws -> AssetRecord {
    try sharedFacade.updateRemoteURL(alias: alias, remoteURL: remoteURL)
}

public func proxyURL(for alias: Alias) throws -> URL {
    try sharedFacade.proxyURL(for: alias)
}

public func proxyURL(for alias: Alias, kind: ProxyResourceKind, remoteURL: URL) throws -> URL {
    try sharedFacade.proxyURL(for: alias, kind: kind, remoteURL: remoteURL)
}

public func decodeProxyRequestURL(_ requestURL: URL) throws -> ProxyRoute {
    try sharedFacade.decodeProxyRequestURL(requestURL)
}

public func cacheInfo(alias: Alias) throws -> CacheInfo {
    try sharedFacade.cacheInfo(alias: alias)
}

public func listAliases() -> [AssetRecord] {
    sharedFacade.listAliases()
}

public func clearCache(alias: Alias? = nil) throws {
    try sharedFacade.clearCache(alias: alias)
}

@discardableResult
public func removeAlias(alias: Alias) throws -> AssetRecord {
    try sharedFacade.removeAlias(alias: alias)
}

@discardableResult
public func removeAllAliases() throws -> Int {
    try sharedFacade.removeAllAliases()
}

@discardableResult
public func setPlugins(_ plugins: [any HLSCachePlugin]) -> [PluginStamp] {
    sharedFacade.setPlugins(plugins)
}

public func makeTransformPipeline() -> TransformPipeline {
    sharedFacade.makeTransformPipeline()
}

private func defaultBaseDirectory() -> URL {
    let defaultRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    return defaultRoot.appendingPathComponent("HLSCache", isDirectory: true)
}
