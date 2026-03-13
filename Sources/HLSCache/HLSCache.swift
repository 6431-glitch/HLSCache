import CoreCache
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

public struct ProxyServerStatus: Sendable, Equatable {
    public let isRunning: Bool
    public let state: ProxyRuntimeState
    public let host: String?
    public let port: Int?
    public let baseURL: URL?

    public init(
        isRunning: Bool,
        host: String?,
        port: Int?,
        baseURL: URL?,
        state: ProxyRuntimeState? = nil
    ) {
        self.isRunning = isRunning
        self.state = state ?? (isRunning ? .running : .stopped)
        self.host = host
        self.port = port
        self.baseURL = baseURL
    }
}

public enum HLSCacheError: Error, Equatable, Sendable {
    case serverNotRunning
    case aliasNotFound(Alias)
}

// Protects mutable runtime fields (server state/plugins) with a dedicated dispatch queue.
public final class HLSCacheFacade: @unchecked Sendable {
    private let fileManager: FileManager
    private let baseDirectory: URL
    private let aliasRegistry: AliasRegistry
    private let logger: any StructuredLogger
    private let networkSession: URLSession
    private let queue = DispatchQueue(label: "HLSCache.Facade", attributes: .concurrent)
    private let proxyRuntime = ProxyServerRuntime()

    private var serverBaseURL: URL?
    private var runtimeState: ProxyRuntimeState = .stopped
    private var plugins: [any HLSCachePlugin] = []

    public init(
        baseDirectory: URL,
        logger: any StructuredLogger = NoopStructuredLogger(),
        networkSession: URLSession = .shared
    ) {
        self.fileManager = .default
        self.baseDirectory = baseDirectory
        self.aliasRegistry = AliasRegistry(baseDirectory: baseDirectory, logger: logger)
        self.logger = logger
        self.networkSession = networkSession
    }

    @discardableResult
    public func startServer(host: String = "127.0.0.1", port: Int = 8080) throws -> URL {
        let correlationID = UUID().uuidString
        return try queue.sync(flags: .barrier) {
            if runtimeState == .running, let existing = serverBaseURL {
                return existing
            }

            runtimeState = .starting
            do {
                let resolvedURL = try proxyRuntime.start(
                    host: host,
                    port: port,
                    requestHandler: makeProxyRequestHandler()
                )
                serverBaseURL = resolvedURL
                runtimeState = .running
                logger.log(
                    StructuredLogEvent(
                        subsystem: "HLSCache",
                        operation: "startServer",
                        level: .info,
                        correlationID: correlationID,
                        metadata: [
                            "host": resolvedURL.host ?? host,
                            "port": resolvedURL.port.map(String.init) ?? String(port),
                            "state": runtimeState.rawValue
                        ]
                    )
                )
                return resolvedURL
            } catch {
                runtimeState = .stopped
                serverBaseURL = nil
                logger.log(
                    StructuredLogEvent(
                        subsystem: "HLSCache",
                        operation: "startServer",
                        level: .error,
                        correlationID: correlationID,
                        metadata: [
                            "host": host,
                            "port": String(port),
                            "state": runtimeState.rawValue,
                            "error": String(describing: error)
                        ]
                    )
                )
                throw error
            }
        }
    }

    public func stopServer() {
        let correlationID = UUID().uuidString
        queue.sync(flags: .barrier) {
            runtimeState = .stopping
            proxyRuntime.stop()
            serverBaseURL = nil
            runtimeState = .stopped
            logger.log(
                StructuredLogEvent(
                    subsystem: "HLSCache",
                    operation: "stopServer",
                    level: .info,
                    correlationID: correlationID,
                    metadata: ["state": runtimeState.rawValue]
                )
            )
        }
    }

    public func proxyStatus() -> ProxyServerStatus {
        let correlationID = UUID().uuidString
        let status = queue.sync {
            if let serverBaseURL, runtimeState == .running {
                return ProxyServerStatus(
                    isRunning: true,
                    host: serverBaseURL.host,
                    port: serverBaseURL.port,
                    baseURL: serverBaseURL,
                    state: runtimeState
                )
            }

            return ProxyServerStatus(
                isRunning: false,
                host: nil,
                port: nil,
                baseURL: nil,
                state: runtimeState
            )
        }

        logger.log(
            StructuredLogEvent(
                subsystem: "HLSCache",
                operation: "proxyStatus",
                level: .debug,
                correlationID: correlationID,
                metadata: [
                    "running": String(status.isRunning),
                    "state": status.state.rawValue,
                    "host": status.host ?? "",
                    "port": status.port.map(String.init) ?? ""
                ]
            )
        )

        return status
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

    private func makeProxyRequestHandler() -> @Sendable (ProxyServerHTTPRequest) async -> ProxyServerHTTPResponse {
        { [weak self] request in
            guard let self else {
                return ProxyServerHTTPResponse.text(
                    statusCode: 500,
                    reasonPhrase: "Internal Server Error",
                    body: "runtime unavailable\n"
                )
            }

            if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
                return await self.handleProxyRequest(request)
            }

            return ProxyServerHTTPResponse.text(
                statusCode: 501,
                reasonPhrase: "Not Implemented",
                body: "proxy request handling requires async runtime support\n"
            )
        }
    }

    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    private func handleProxyRequest(_ request: ProxyServerHTTPRequest) async -> ProxyServerHTTPResponse {
        let correlationID = UUID().uuidString

        let requestURL: URL
        do {
            requestURL = try makeRequestURL(for: request.path)
        } catch {
            logger.log(
                StructuredLogEvent(
                    subsystem: "HLSCache",
                    operation: "proxyRequest",
                    level: .warning,
                    correlationID: correlationID,
                    metadata: [
                        "path": request.path,
                        "method": request.method,
                        "status": "400",
                        "error": String(describing: error)
                    ]
                )
            )
            return .text(statusCode: 400, reasonPhrase: "Bad Request", body: "invalid route\n")
        }

        let route: ProxyRoute
        let asset: AssetRecord
        do {
            route = try decodeProxyRequestURL(requestURL)
            guard let resolved = aliasRegistry.resolve(alias: route.alias) else {
                throw HLSCacheError.aliasNotFound(route.alias)
            }
            asset = resolved
        } catch HLSCacheError.aliasNotFound {
            logger.log(
                StructuredLogEvent(
                    subsystem: "HLSCache",
                    operation: "proxyRequest",
                    level: .warning,
                    correlationID: correlationID,
                    metadata: [
                        "path": request.path,
                        "method": request.method,
                        "status": "404"
                    ]
                )
            )
            return .text(statusCode: 404, reasonPhrase: "Not Found", body: "alias not found\n")
        } catch {
            logger.log(
                StructuredLogEvent(
                    subsystem: "HLSCache",
                    operation: "proxyRequest",
                    level: .warning,
                    correlationID: correlationID,
                    metadata: [
                        "path": request.path,
                        "method": request.method,
                        "status": "400",
                        "error": String(describing: error)
                    ]
                )
            )
            return .text(statusCode: 400, reasonPhrase: "Bad Request", body: "invalid route\n")
        }

        let resourceID = ResourceID(
            cacheKey: asset.cacheKey,
            kind: route.kind.coreCacheKind,
            resourceKey: ResourceID.makeResourceKey(from: route.remoteURL)
        )

        let coordinator: ProxyCacheCoordinator
        let totalLength: Int64
        let contentType: String?
        let requestHeaders = asset.headers ?? [:]
        do {
            let cache = try CoreCache(baseDirectory: baseDirectory, logger: logger)
            coordinator = ProxyCacheCoordinator(
                coreCache: cache,
                transformPipeline: makeTransformPipeline()
            )
            let cachedRecord = try cache.record(resource: resourceID)
            let metadata = try await resolveRemoteMetadataIfNeeded(
                cachedRecord: cachedRecord,
                remoteURL: route.remoteURL,
                requestHeaders: requestHeaders,
                networkClient: URLSessionNetworkClient(session: networkSession)
            )
            totalLength = metadata.totalLength
            contentType = metadata.contentType
        } catch {
            logger.log(
                StructuredLogEvent(
                    subsystem: "HLSCache",
                    operation: "proxyRequest",
                    level: .error,
                    correlationID: correlationID,
                    metadata: [
                        "path": request.path,
                        "method": request.method,
                        "status": "502",
                        "error": String(describing: error)
                    ]
                )
            )
            return .text(statusCode: 502, reasonPhrase: "Bad Gateway", body: "upstream metadata unavailable\n")
        }

        let rangeHeader = request.headers["range"]
        do {
            if request.method == "HEAD" {
                let response = try ProxyRangeResponse.make(
                    rangeHeader: rangeHeader,
                    totalLength: totalLength
                )
                var headers = response.headers
                if let contentType {
                    headers["Content-Type"] = contentType
                }
                logger.log(
                    StructuredLogEvent(
                        subsystem: "HLSCache",
                        operation: "proxyRequest",
                        level: .debug,
                        correlationID: correlationID,
                        metadata: [
                            "alias": route.alias,
                            "kind": route.kind.rawValue,
                            "status": String(response.statusCode),
                            "bytes": headers["Content-Length"] ?? "0"
                        ]
                    )
                )
                return ProxyServerHTTPResponse(
                    statusCode: response.statusCode,
                    reasonPhrase: reasonPhrase(for: response.statusCode),
                    headers: headers,
                    body: Data()
                )
            }

            let networkClient = URLSessionNetworkClient(session: networkSession)
            var payload = Data()
            let result = try await coordinator.serveStreaming(
                resourceID: resourceID,
                remoteURL: route.remoteURL,
                headers: requestHeaders,
                rangeHeader: rangeHeader,
                totalLength: totalLength,
                contentType: contentType,
                allowNetworkFallback: true,
                networkClient: networkClient
            ) { _, chunk in
                payload.append(chunk)
            }

            var headers = result.response.headers
            if let contentType {
                headers["Content-Type"] = contentType
            }

            logger.log(
                StructuredLogEvent(
                    subsystem: "HLSCache",
                    operation: "proxyRequest",
                    level: .debug,
                    correlationID: correlationID,
                    metadata: [
                        "alias": route.alias,
                        "kind": route.kind.rawValue,
                        "status": String(result.response.statusCode),
                        "bytes": String(payload.count)
                    ]
                )
            )

            return ProxyServerHTTPResponse(
                statusCode: result.response.statusCode,
                reasonPhrase: reasonPhrase(for: result.response.statusCode),
                headers: headers,
                body: payload
            )
        } catch {
            logger.log(
                StructuredLogEvent(
                    subsystem: "HLSCache",
                    operation: "proxyRequest",
                    level: .error,
                    correlationID: correlationID,
                    metadata: [
                        "alias": route.alias,
                        "kind": route.kind.rawValue,
                        "path": request.path,
                        "method": request.method,
                        "status": "502",
                        "error": String(describing: error)
                    ]
                )
            )
            return .text(statusCode: 502, reasonPhrase: "Bad Gateway", body: "proxy upstream error\n")
        }
    }

    private func makeRequestURL(for path: String) throws -> URL {
        guard var components = URLComponents(string: "http://localhost") else {
            throw ProxyRouteError.invalidRoutePath(path)
        }
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        components.percentEncodedPath = normalizedPath
        guard let url = components.url else {
            throw ProxyRouteError.invalidRoutePath(path)
        }
        return url
    }

    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    private func resolveRemoteMetadataIfNeeded(
        cachedRecord: ResourceRecord?,
        remoteURL: URL,
        requestHeaders: [String: String],
        networkClient: any NetworkClient
    ) async throws -> (totalLength: Int64, contentType: String?) {
        if let expectedLength = cachedRecord?.expectedLength, expectedLength >= 0 {
            return (expectedLength, cachedRecord?.contentType)
        }

        var headRequest = URLRequest(url: remoteURL)
        headRequest.httpMethod = "HEAD"
        for (name, value) in requestHeaders {
            headRequest.setValue(value, forHTTPHeaderField: name)
        }

        do {
            let (_, response) = try await networkClient.data(for: headRequest)
            if let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode),
               let contentLength = parseContentLength(from: httpResponse) {
                return (contentLength, parseContentType(from: httpResponse))
            }
        } catch {
            // Fall back to range probe when HEAD is unsupported or unavailable.
        }

        var probeRequest = URLRequest(url: remoteURL)
        probeRequest.httpMethod = "GET"
        probeRequest.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        for (name, value) in requestHeaders {
            probeRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (probeData, probeResponse) = try await networkClient.data(for: probeRequest)
        guard let probeHTTPResponse = probeResponse as? HTTPURLResponse else {
            throw NetworkClientError.nonHTTPResponse
        }
        let totalLength = parseTotalLengthFromContentRange(headerValue("Content-Range", in: probeHTTPResponse))
            ?? parseContentLength(from: probeHTTPResponse)
            ?? Int64(probeData.count)
        return (totalLength, parseContentType(from: probeHTTPResponse))
    }

    private func parseContentLength(from response: HTTPURLResponse) -> Int64? {
        guard let value = headerValue("Content-Length", in: response) else {
            return nil
        }
        return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func parseContentType(from response: HTTPURLResponse) -> String? {
        headerValue("Content-Type", in: response) ?? response.mimeType
    }

    private func parseTotalLengthFromContentRange(_ header: String?) -> Int64? {
        guard let header else {
            return nil
        }
        guard let slashIndex = header.lastIndex(of: "/") else {
            return nil
        }
        let lengthPart = header[header.index(after: slashIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard lengthPart != "*" else {
            return nil
        }
        return Int64(lengthPart)
    }

    private func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 206:
            return "Partial Content"
        case 400:
            return "Bad Request"
        case 404:
            return "Not Found"
        case 416:
            return "Range Not Satisfiable"
        case 502:
            return "Bad Gateway"
        default:
            return "Internal Server Error"
        }
    }

    private func headerValue(_ name: String, in response: HTTPURLResponse) -> String? {
        for (headerName, headerValue) in response.allHeaderFields {
            guard let key = headerName as? String else {
                continue
            }
            if key.caseInsensitiveCompare(name) == .orderedSame {
                return String(describing: headerValue)
            }
        }
        return nil
    }
}

private let sharedFacade = HLSCacheFacade(baseDirectory: defaultBaseDirectory())

public func startServer(host: String = "127.0.0.1", port: Int = 8080) throws -> URL {
    try sharedFacade.startServer(host: host, port: port)
}

public func stopServer() {
    sharedFacade.stopServer()
}

public func proxyStatus() -> ProxyServerStatus {
    sharedFacade.proxyStatus()
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
