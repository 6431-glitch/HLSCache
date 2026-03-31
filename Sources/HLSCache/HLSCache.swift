import CoreCache
import Foundation
import Logging

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
    public let offlineModeEnabled: Bool

    public init(
        isRunning: Bool,
        host: String?,
        port: Int?,
        baseURL: URL?,
        state: ProxyRuntimeState? = nil,
        offlineModeEnabled: Bool = false
    ) {
        self.isRunning = isRunning
        self.state = state ?? (isRunning ? .running : .stopped)
        self.host = host
        self.port = port
        self.baseURL = baseURL
        self.offlineModeEnabled = offlineModeEnabled
    }
}

public enum HLSCacheError: Error, Equatable, Sendable {
    case serverNotRunning
    case aliasNotFound(Alias)
}

public final class HLSCacheFacade: @unchecked Sendable, HLSLoggable {
    private let fileManager: FileManager
    private let baseDirectory: URL
    private let aliasRegistry: AliasRegistry
    private let overrideLogger: Logger?
    private let networkClient: any NetworkClient
    private let coreCacheStartupReconciliationMode: StartupReconciliationMode
    private let coreCacheStartupReconciliationProgressInterval: Int
    private let queue = DispatchQueue(label: "HLSCache.Facade", attributes: .concurrent)
    private let proxyRuntime = ProxyServerRuntime()

    private var serverBaseURL: URL?
    private var runtimeState: ProxyRuntimeState = .stopped
    private var plugins: [any HLSCachePlugin] = []
    private var offlinePlaybackModeEnabled = false

    public init(
        baseDirectory: URL,
        logger: Logger? = nil,
        coreCacheStartupReconciliationMode: StartupReconciliationMode = .synchronous,
        coreCacheStartupReconciliationProgressInterval: Int = 128,
        networkSession: URLSession = .shared,
        networkClient: (any NetworkClient)? = nil
    ) {
        self.fileManager = .default
        self.baseDirectory = baseDirectory
        self.aliasRegistry = AliasRegistry(baseDirectory: baseDirectory, logger: logger)
        self.overrideLogger = logger
        self.coreCacheStartupReconciliationMode = coreCacheStartupReconciliationMode
        self.coreCacheStartupReconciliationProgressInterval = max(1, coreCacheStartupReconciliationProgressInterval)
        self.networkClient = networkClient ?? GetNetworkClient.pulseEnabled(
            sessionConfiguration: networkSession.configuration,
            sessionDelegate: networkSession.delegate
        )
    }

    @discardableResult
    public func startServer(host: String = "127.0.0.1", port: Int = 8080) throws -> URL {
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
                logger.info("Proxy server started at \(resolvedURL.absoluteString)")
                return resolvedURL
            } catch {
                runtimeState = .stopped
                serverBaseURL = nil
                logger.error("Failed to start proxy server: \(error.localizedDescription)")
                throw error
            }
        }
    }

    public func stopServer() {
        queue.sync(flags: .barrier) {
            runtimeState = .stopping
            proxyRuntime.stop()
            serverBaseURL = nil
            runtimeState = .stopped
            activeLogger.info("Proxy server stopped.")
        }
    }

    public func proxyStatus() -> ProxyServerStatus {
        let status = queue.sync {
            let state = runtimeState
            let offlineModeEnabled = offlinePlaybackModeEnabled
            if let serverBaseURL, state == .running {
                return ProxyServerStatus(
                    isRunning: true,
                    host: serverBaseURL.host,
                    port: serverBaseURL.port,
                    baseURL: serverBaseURL,
                    state: state,
                    offlineModeEnabled: offlineModeEnabled
                )
            }

            return ProxyServerStatus(
                isRunning: false,
                host: nil,
                port: nil,
                baseURL: nil,
                state: state,
                offlineModeEnabled: offlineModeEnabled
            )
        }

        activeLogger.debug(
            "Proxy status is \(status.state.rawValue), running=\(status.isRunning), offlineMode=\(status.offlineModeEnabled)"
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
        let record = try aliasRegistry.register(alias: alias, assetID: assetID, remoteURL: remoteURL, headers: headers)
        activeLogger.info("Registered alias \(alias) for remote URL \(remoteURL.absoluteString)")
        return record
    }

    @discardableResult
    /// Rotates alias metadata to a new remote URL while preserving asset identity (`AssetID`/`CacheKey`).
    /// Resource-byte continuity remains strict URL-based, so cross-origin or otherwise different canonical
    /// resource URLs are treated as cache misses and fetched under new resource keys.
    public func updateRemoteURL(alias: Alias, remoteURL: URL) throws -> AssetRecord {
        let previous = aliasRegistry.resolve(alias: alias)
        let updated = try aliasRegistry.updateRemoteURL(alias: alias, remoteURL: remoteURL)
        let previousHost = previous?.currentRemoteURL.host
        let updatedHost = updated.currentRemoteURL.host
        let hostChanged = previousHost != updatedHost
        activeLogger.info(
            "Updated remote URL for alias \(alias) from \(previous?.currentRemoteURL.absoluteString ?? "none") to \(updated.currentRemoteURL.absoluteString); hostChanged=\(hostChanged)"
        )
        return updated
    }

    public func listAliases() -> [AssetRecord] {
        let records = aliasRegistry.allRecords()
        activeLogger.debug("Listing aliases returned \(records.count) record(s).")
        return records
    }

    public func proxyURL(for alias: Alias) throws -> URL {
        let base = queue.sync { serverBaseURL }
        guard let base else {
            throw HLSCacheError.serverNotRunning
        }

        guard let record = aliasRegistry.resolve(alias: alias) else {
            throw HLSCacheError.aliasNotFound(alias)
        }

        let route = ProxyRoute(alias: alias, kind: .raw, remoteURL: record.currentRemoteURL)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw ProxyRouteError.invalidEncodedURL(base.absoluteString)
        }

        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let routePath = try [
            route.encodedAlias(),
            ProxyResourceKind.raw.rawValue,
            route.encodedRemoteURL()
        ].joined(separator: "/")

        if basePath.isEmpty {
            components.percentEncodedPath = "/" + routePath
        } else {
            components.percentEncodedPath = "/" + basePath + "/" + routePath
        }

        guard let url = components.url else {
            throw ProxyRouteError.invalidEncodedURL(record.currentRemoteURL.absoluteString)
        }

        activeLogger.debug("Generated proxy URL for alias \(alias) using raw route.")
        return url
    }

    public func proxyURL(for alias: Alias, kind: ProxyResourceKind, remoteURL: URL) throws -> URL {
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

        activeLogger.debug("Generated proxy URL for alias \(alias), kind \(kind.rawValue).")
        return url
    }

    public func decodeProxyRequestURL(_ requestURL: URL) throws -> ProxyRoute {
        let route = try ProxyRoute.from(url: requestURL)
        guard aliasRegistry.resolve(alias: route.alias) != nil else {
            throw HLSCacheError.aliasNotFound(route.alias)
        }
        activeLogger.debug("Decoded proxy request URL for alias \(route.alias), kind \(route.kind.rawValue).")
        return route
    }

    public func cacheInfo(alias: Alias) throws -> CacheInfo {
        guard let record = aliasRegistry.resolve(alias: alias) else {
            throw HLSCacheError.aliasNotFound(alias)
        }

        let pluginCount = queue.sync { plugins.count }
        let bytes = directorySize(at: cacheDirectory(for: record.cacheKey))
        activeLogger.debug("Loaded cache info for alias \(alias) with \(bytes) bytes on disk.")

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
        try queue.sync(flags: .barrier) {
            if let alias {
                guard let record = aliasRegistry.resolve(alias: alias) else {
                    throw HLSCacheError.aliasNotFound(alias)
                }
                try removeDirectoryIfPresent(at: cacheDirectory(for: record.cacheKey))
                logger.warning("Cleared cache files for alias \(alias).")
                return
            }

            try removeDirectoryIfPresent(at: baseDirectory.appendingPathComponent("cache", isDirectory: true))
            activeLogger.warning("Cleared all cache files.")
        }
    }

    @discardableResult
    public func removeAlias(alias: Alias) throws -> AssetRecord {
        do {
            let removed = try aliasRegistry.unregister(alias: alias)
            activeLogger.warning("Removed alias \(alias) from registry.")
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
        let removedCount = try aliasRegistry.unregisterAll()
        activeLogger.warning("Removed all aliases (\(removedCount) record(s)).")
        return removedCount
    }

    @discardableResult
    public func setPlugins(_ plugins: [any HLSCachePlugin]) -> [PluginStamp] {
        return queue.sync(flags: .barrier) {
            self.plugins = plugins
            let pluginStamps = plugins.map { PluginStamp(id: $0.id, version: $0.version) }
            activeLogger.info("Updated active plugins to \(pluginStamps.count) plugin(s).")
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

    @discardableResult
    public func setOfflinePlaybackMode(enabled: Bool) -> Bool {
        return queue.sync(flags: .barrier) {
            offlinePlaybackModeEnabled = enabled
            activeLogger.info("Offline playback mode is now \(enabled).")
            return offlinePlaybackModeEnabled
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
        let offlineModeEnabled = queue.sync { offlinePlaybackModeEnabled }

        let requestURL: URL
        do {
            requestURL = try makeRequestURL(for: request.path)
        } catch {
            activeLogger.warning("Proxy request rejected because route path is invalid: \(request.path)")
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
        } catch let HLSCacheError.aliasNotFound(missingAlias) {
            activeLogger.warning("Proxy request rejected because alias \(missingAlias) was not found.")
            return .text(statusCode: 404, reasonPhrase: "Not Found", body: "alias not found\n")
        } catch {
            activeLogger.warning("Proxy request rejected because route decoding failed: \(request.path)")
            return .text(statusCode: 400, reasonPhrase: "Bad Request", body: "invalid route\n")
        }

        let requestHeaders = asset.headers ?? [:]
        if !offlineModeEnabled,
           request.headers["range"] == nil,
           (request.method == "GET" || request.method == "HEAD"),
           looksLikePlaylistURL(route.remoteURL) {
            return await proxyResponseForPlaylistRequest(
                route: route,
                requestPath: request.path,
                requestMethod: request.method,
                requestHeaders: requestHeaders
            )
        }

        let primaryResourceID = ResourceID(
            cacheKey: asset.cacheKey,
            kind: route.kind.coreCacheKind,
            resourceKey: ResourceID.makeResourceKey(from: route.remoteURL)
        )
        let legacyFallbackResourceIDs = ResourceID.makeLegacyResourceKeyCandidates(from: route.remoteURL).map {
            ResourceID(
                cacheKey: asset.cacheKey,
                kind: route.kind.coreCacheKind,
                resourceKey: $0
            )
        }

        let resourceID: ResourceID
        let coordinator: ProxyCacheCoordinator
        let totalLength: Int64
        let contentType: String?
        let continuityDecision: String
        do {
            let cache = try CoreCache(
                baseDirectory: baseDirectory,
                startupReconciliationMode: coreCacheStartupReconciliationMode,
                startupReconciliationProgressInterval: coreCacheStartupReconciliationProgressInterval,
                logger: activeLogger
            )
            coordinator = ProxyCacheCoordinator(
                coreCache: cache,
                transformPipeline: makeTransformPipeline()
            )
            let primaryCachedRecord = try cache.record(resource: primaryResourceID)
            var selectedResourceID = primaryResourceID
            var selectedCachedRecord = primaryCachedRecord
            var selectedContinuityDecision = "miss_new_resource_url"

            if primaryCachedRecord != nil {
                selectedContinuityDecision = "reuse_existing_resource_url"
            } else {
                for legacyResourceID in legacyFallbackResourceIDs {
                    guard let fallbackRecord = try cache.record(resource: legacyResourceID) else {
                        continue
                    }
                    selectedResourceID = legacyResourceID
                    selectedCachedRecord = fallbackRecord
                    selectedContinuityDecision = "reuse_legacy_resource_key_fallback"
                    logger.info("Using legacy cached resource key for URL \(route.remoteURL.absoluteString)")
                    break
                }
            }

            resourceID = selectedResourceID
            continuityDecision = selectedContinuityDecision

            if offlineModeEnabled {
                guard let expectedLength = selectedCachedRecord?.expectedLength, expectedLength >= 0 else {
                    throw ProxyCacheCoordinatorError.offlineCacheMiss(range: ByteRange(start: 0, endExclusive: 0)!)
                }
                totalLength = expectedLength
                contentType = selectedCachedRecord?.contentType
            } else {
                let metadata = try await resolveRemoteMetadataIfNeeded(
                    cachedRecord: selectedCachedRecord,
                    remoteURL: route.remoteURL,
                    requestHeaders: requestHeaders,
                    networkClient: networkClient
                )
                totalLength = metadata.totalLength
                contentType = metadata.contentType
            }
        } catch let error as ProxyCacheCoordinatorError {
            if case let .offlineCacheMiss(range) = error {
                logger.warning(
                    "Proxy request offline cache miss for \(route.remoteURL.absoluteString), missing bytes \(range.start)-\(range.endExclusive)"
                )
                return ProxyServerHTTPResponse(
                    statusCode: 503,
                    reasonPhrase: "Service Unavailable",
                    headers: Self.offlineCacheMissHeaders(range: range),
                    body: Data("offline cache miss\n".utf8)
                )
            }

            activeLogger.error("Proxy request failed while preparing metadata: \(error.localizedDescription)")
            return .text(statusCode: 502, reasonPhrase: "Bad Gateway", body: "upstream metadata unavailable\n")
        } catch {
            activeLogger.error("Proxy request failed while preparing metadata: \(error.localizedDescription)")
            return .text(statusCode: 502, reasonPhrase: "Bad Gateway", body: "upstream metadata unavailable\n")
        }

        let rangeHeader = request.headers["range"]
        do {
            let response = try ProxyRangeResponse.make(
                rangeHeader: rangeHeader,
                totalLength: totalLength
            )
            var headers = response.headers
            if let contentType {
                headers["Content-Type"] = contentType
            }

            if request.method == "HEAD" || response.statusCode == 416 {
                logger.debug("Proxy request \(request.method) \(request.path) responded with status \(response.statusCode) without body.")

                return ProxyServerHTTPResponse(
                    statusCode: response.statusCode,
                    reasonPhrase: reasonPhrase(for: response.statusCode),
                    headers: headers,
                    body: Data()
                )
            }

            activeLogger.debug("Starting proxy response stream for \(request.method) \(request.path).")

            return ProxyServerHTTPResponse(
                statusCode: response.statusCode,
                reasonPhrase: reasonPhrase(for: response.statusCode),
                headers: headers,
                bodyStream: makeProxyResponseBodyStream(
                    coordinator: coordinator,
                    resourceID: resourceID,
                    remoteURL: route.remoteURL,
                    headers: requestHeaders,
                    rangeHeader: rangeHeader,
                    totalLength: totalLength,
                    contentType: contentType,
                    allowNetworkFallback: !offlineModeEnabled,
                    correlationID: correlationID,
                    alias: route.alias,
                    kind: route.kind.rawValue,
                    continuityDecision: continuityDecision,
                    offlineModeEnabled: offlineModeEnabled,
                    requestPath: request.path,
                    requestMethod: request.method
                )
            )
        } catch {
            activeLogger.error("Proxy request failed before streaming response body: \(error.localizedDescription)")
            return .text(statusCode: 502, reasonPhrase: "Bad Gateway", body: "proxy upstream error\n")
        }
    }

    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    private func proxyResponseForPlaylistRequest(
        route: ProxyRoute,
        requestPath: String,
        requestMethod: String,
        requestHeaders: [String: String]
    ) async -> ProxyServerHTTPResponse {
        var upstreamRequest = URLRequest(url: route.remoteURL)
        upstreamRequest.httpMethod = "GET"
        for (name, value) in requestHeaders {
            upstreamRequest.setValue(value, forHTTPHeaderField: name)
        }

        do {
            let (upstreamData, upstreamResponse) = try await networkClient.data(for: upstreamRequest)
            guard let httpResponse = upstreamResponse as? HTTPURLResponse else {
                activeLogger.error("Proxy playlist request failed with non-HTTP response: \(route.remoteURL.absoluteString)")
                return .text(statusCode: 502, reasonPhrase: "Bad Gateway", body: "proxy upstream error\n")
            }

            let contentType = headerValue("Content-Type", in: httpResponse) ?? "application/vnd.apple.mpegurl"
            guard (200...299).contains(httpResponse.statusCode) else {
                let body = requestMethod == "HEAD" ? Data() : upstreamData
                return ProxyServerHTTPResponse(
                    statusCode: httpResponse.statusCode,
                    reasonPhrase: reasonPhrase(for: httpResponse.statusCode),
                    headers: [
                        "Content-Type": contentType,
                        "Content-Length": String(upstreamData.count),
                        "Accept-Ranges": "bytes"
                    ],
                    body: body
                )
            }

            let rewrittenData: Data
            if let playlist = String(data: upstreamData, encoding: .utf8) {
                let rewritten = try HLSPlaylistRewriter.rewrite(
                    playlist,
                    alias: route.alias,
                    playlistURL: route.remoteURL
                ) { [self] alias, kind, remoteURL in
                    try proxyURL(for: alias, kind: kind, remoteURL: remoteURL)
                }
                rewrittenData = Data(rewritten.utf8)
            } else {
                rewrittenData = upstreamData
            }

            let responseBody = requestMethod == "HEAD" ? Data() : rewrittenData
            activeLogger.debug("Proxy playlist rewrite succeeded for \(requestPath).")
            return ProxyServerHTTPResponse(
                statusCode: 200,
                reasonPhrase: "OK",
                headers: [
                    "Content-Type": contentType,
                    "Content-Length": String(rewrittenData.count),
                    "Accept-Ranges": "bytes"
                ],
                body: responseBody
            )
        } catch {
            activeLogger.error("Proxy playlist rewrite failed for \(requestPath): \(error.localizedDescription)")
            return .text(statusCode: 502, reasonPhrase: "Bad Gateway", body: "proxy upstream error\n")
        }
    }

    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    private func makeProxyResponseBodyStream(
        coordinator: ProxyCacheCoordinator,
        resourceID: ResourceID,
        remoteURL: URL,
        headers: [String: String],
        rangeHeader: String?,
        totalLength: Int64,
        contentType: String?,
        allowNetworkFallback: Bool,
        correlationID: String,
        alias: String,
        kind: String,
        continuityDecision: String,
        offlineModeEnabled: Bool,
        requestPath: String,
        requestMethod: String
    ) -> @Sendable (_ emitChunk: @escaping (Data) async throws -> Void) async throws -> Void {
        { [logger = activeLogger, networkClient] emitChunk in
            do {
                let result = try await coordinator.serveStreaming(
                    resourceID: resourceID,
                    remoteURL: remoteURL,
                    headers: headers,
                    rangeHeader: rangeHeader,
                    totalLength: totalLength,
                    contentType: contentType,
                    allowNetworkFallback: allowNetworkFallback,
                    networkClient: networkClient,
                    correlationID: correlationID
                ) { _, chunk in
                    try await emitChunk(chunk)
                }

                logger.debug(
                    "Proxy stream completed for alias \(alias) (\(kind)) with \(result.totalBytesStreamed) byte(s) over \(result.chunks.count) chunk(s)."
                )
            } catch let error as ProxyServerHTTPBodyStreamError {
                throw error
            } catch let error as ProxyCacheCoordinatorError {
                if case let .offlineCacheMiss(range) = error {
                    logger.warning(
                        "Proxy stream offline cache miss for alias \(alias), missing bytes \(range.start)-\(range.endExclusive)."
                    )
                    throw ProxyServerHTTPBodyStreamError.fallbackResponseWithHeaders(
                        statusCode: 503,
                        reasonPhrase: "Service Unavailable",
                        headers: Self.offlineCacheMissHeaders(range: range),
                        body: "offline cache miss\n"
                    )
                }

                logger.error("Proxy stream failed for alias \(alias): \(error.localizedDescription)")
                throw ProxyServerHTTPBodyStreamError.fallbackResponse(
                    statusCode: 502,
                    reasonPhrase: "Bad Gateway",
                    body: "proxy upstream error\n"
                )
            } catch {
                logger.error("Proxy stream failed for alias \(alias): \(error.localizedDescription)")
                throw ProxyServerHTTPBodyStreamError.fallbackResponse(
                    statusCode: 502,
                    reasonPhrase: "Bad Gateway",
                    body: "proxy upstream error\n"
                )
            }
        }
    }

    private func looksLikePlaylistURL(_ remoteURL: URL) -> Bool {
        remoteURL.path.lowercased().contains(".m3u8")
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
        case 503:
            return "Service Unavailable"
        default:
            return "Internal Server Error"
        }
    }

    private static func offlineCacheMissHeaders(range: ByteRange) -> [String: String] {
        [
            "Content-Type": "text/plain; charset=utf-8",
            "X-HLSCache-Diagnostic-Schema": "1",
            "X-HLSCache-Error-Code": "offline_cache_miss",
            "X-HLSCache-Offline-Mode": "true",
            "X-HLSCache-Missing-Start": String(range.start),
            "X-HLSCache-Missing-End-Exclusive": String(range.endExclusive)
        ]
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

    private var activeLogger: Logger {
        overrideLogger ?? logger
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
public func setOfflinePlaybackMode(enabled: Bool) -> Bool {
    sharedFacade.setOfflinePlaybackMode(enabled: enabled)
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
