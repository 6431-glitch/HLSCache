import CoreCache
import Foundation
import Logging
import Testing
@testable import HLSCache

#if canImport(Darwin)
import Darwin
#endif

private struct TestPlugin: HLSCachePlugin {
    let id: String
    let version: String
}

private final class LogEventStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [StructuredLogEvent] = []

    func append(_ event: StructuredLogEvent) {
        lock.lock()
        storedEvents.append(event)
        lock.unlock()
    }

    func events() -> [StructuredLogEvent] {
        lock.lock()
        let snapshot = storedEvents
        lock.unlock()
        return snapshot
    }
}

private struct RecordingLogHandler: LogHandler {
    let store: LogEventStore
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source _: String,
        file _: String,
        function _: String,
        line _: UInt
    ) {
        var merged = self.metadata
        if let metadata {
            for (key, value) in metadata {
                merged[key] = value
            }
        }

        let parsed = parseOperationAndMetadata(from: "\(message)")
        var parsedMetadata = parsed.metadata
        for (key, value) in merged where parsedMetadata[key] == nil {
            parsedMetadata[key] = value.stringValue
        }

        store.append(
            StructuredLogEvent(
                subsystem: merged["subsystem"]?.stringValue ?? "",
                operation: merged["operation"]?.stringValue ?? parsed.operation,
                level: level,
                correlationID: merged["correlationID"]?.stringValue ?? "n/a",
                metadata: parsedMetadata,
                timestamp: Date()
            )
        )
    }
}

private final class RecordingStructuredLogger: HLSLoggable, @unchecked Sendable {
    private let store: LogEventStore
    let logger: Logger

    init(label: String = "tests.hlscache", minimumLevel: Logger.Level = .trace) {
        let store = LogEventStore()
        self.store = store
        var built = Logger(label: label) { _ in
            RecordingLogHandler(store: store)
        }
        built.logLevel = minimumLevel
        self.logger = built
    }

    func events() -> [StructuredLogEvent] {
        store.events()
    }
}

private extension Logger.MetadataValue {
    var stringValue: String {
        switch self {
        case let .string(value):
            return value
        case let .stringConvertible(value):
            return String(describing: value)
        default:
            return "\(self)"
        }
    }
}

private func makeHLSCacheTempDirectory(prefix: String = "hlscache-tests") throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(prefix)
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeResourceID(cacheKey: CacheKey, key: String) -> ResourceID {
    ResourceID(cacheKey: cacheKey, kind: .segment, resourceKey: key)
}

@Test func facade_startServer_register_proxyURL_updateRemoteURL() throws {
    let directory = try makeHLSCacheTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let facade = HLSCacheFacade(baseDirectory: directory)

    _ = try facade.register(
        alias: "MD0534",
        assetID: "asset-0534",
        remoteURL: try #require(URL(string: "https://cdn.example.com/master.m3u8")),
        headers: ["X-Test": "1"]
    )

    do {
        _ = try facade.proxyURL(for: "MD0534")
        #expect(Bool(false))
    } catch let error as HLSCacheError {
        #expect(error == .serverNotRunning)
    }

    let baseURL = try facade.startServer(port: 0)
    #expect(baseURL.host == "127.0.0.1")
    #expect((baseURL.port ?? 0) > 0)

    let proxy = try facade.proxyURL(for: "MD0534")
    let route = try facade.decodeProxyRequestURL(proxy)
    #expect(route.alias == "MD0534")
    #expect(route.kind == .raw)
    #expect(route.remoteURL.absoluteString == "https://cdn.example.com/master.m3u8")

    let updated = try facade.updateRemoteURL(
        alias: "MD0534",
        remoteURL: try #require(URL(string: "https://cdn2.example.com/master.m3u8"))
    )
    #expect(updated.currentRemoteURL.absoluteString == "https://cdn2.example.com/master.m3u8")
}

@Test func facade_logger_receivesDebugEvents() throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-logger-debug")
    defer { try? FileManager.default.removeItem(at: directory) }

    let logger = RecordingStructuredLogger()
    let facade = HLSCacheFacade(
        baseDirectory: directory,
        logger: logger.logger
    )

    _ = facade.listAliases()

    let event = try #require(logger.events().first { $0.operation == "listAliases" })
    #expect(event.level == .debug)
}

@Test func facade_logger_respectsMinimumLogLevel() throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-logger-filter")
    defer { try? FileManager.default.removeItem(at: directory) }

    let logger = RecordingStructuredLogger(minimumLevel: .warning)
    let facade = HLSCacheFacade(
        baseDirectory: directory,
        logger: logger.logger
    )

    _ = facade.listAliases()
    _ = facade.proxyStatus()

    #expect(logger.events().isEmpty)
}

@Test func facade_proxyStatus_reportsDeterministicLifecycleState() throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-proxy-status")
    defer { try? FileManager.default.removeItem(at: directory) }

    let facade = HLSCacheFacade(baseDirectory: directory)

    let initial = facade.proxyStatus()
    #expect(initial.isRunning == false)
    #expect(initial.state == .stopped)
    #expect(initial.host == nil)
    #expect(initial.port == nil)
    #expect(initial.baseURL == nil)
    #expect(initial.offlineModeEnabled == false)

    _ = try facade.startServer(host: "127.0.0.1", port: 0)
    let started = facade.proxyStatus()
    #expect(started.isRunning == true)
    #expect(started.state == .running)
    #expect(started.host == "127.0.0.1")
    #expect((started.port ?? 0) > 0)
    #expect(started.baseURL?.host == "127.0.0.1")
    #expect(started.baseURL?.port == started.port)
    #expect(started.offlineModeEnabled == false)

    _ = try facade.startServer(host: "127.0.0.1", port: 19999)
    let restartedWithoutStop = facade.proxyStatus()
    #expect(restartedWithoutStop == started)

    facade.stopServer()
    let stopped = facade.proxyStatus()
    #expect(stopped.isRunning == false)
    #expect(stopped.state == .stopped)
    #expect(stopped.host == nil)
    #expect(stopped.port == nil)
    #expect(stopped.baseURL == nil)
    #expect(stopped.offlineModeEnabled == false)

    _ = try facade.startServer(port: 0)
    let defaultPort = facade.proxyStatus()
    #expect(defaultPort.isRunning == true)
    #expect(defaultPort.state == .running)
    #expect(defaultPort.host == "127.0.0.1")
    #expect((defaultPort.port ?? 0) > 0)
    #expect(defaultPort.baseURL?.host == "127.0.0.1")
    #expect(defaultPort.baseURL?.port == defaultPort.port)
    #expect(defaultPort.offlineModeEnabled == false)
}

@Test func facade_proxyStatus_reportsOfflineModeEnabledAndDisabled() throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-proxy-status-offline")
    defer { try? FileManager.default.removeItem(at: directory) }

    let facade = HLSCacheFacade(baseDirectory: directory)
    _ = try facade.startServer(host: "127.0.0.1", port: 0)
    defer { facade.stopServer() }

    let initiallyDisabled = facade.proxyStatus()
    #expect(initiallyDisabled.isRunning == true)
    #expect(initiallyDisabled.offlineModeEnabled == false)

    let enabled = facade.setOfflinePlaybackMode(enabled: true)
    #expect(enabled == true)
    let enabledStatus = facade.proxyStatus()
    #expect(enabledStatus.isRunning == true)
    #expect(enabledStatus.offlineModeEnabled == true)

    let disabled = facade.setOfflinePlaybackMode(enabled: false)
    #expect(disabled == false)
    let disabledStatus = facade.proxyStatus()
    #expect(disabledStatus.isRunning == true)
    #expect(disabledStatus.offlineModeEnabled == false)
}

@Test func facade_updateRemoteURL_preservesAliasProxyAndExistingCacheData() throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-remote-rotation")
    defer { try? FileManager.default.removeItem(at: directory) }

    let facade = HLSCacheFacade(baseDirectory: directory)
    let initialRemoteURL = try #require(URL(string: "https://origin-a.example.com/master.m3u8"))
    let record = try facade.register(
        alias: "MDROT",
        assetID: "asset-rotation",
        remoteURL: initialRemoteURL
    )

    _ = try facade.startServer(port: 0)
    let proxyBefore = try facade.proxyURL(for: "MDROT")

    let coreCache = try CoreCache(baseDirectory: directory)
    let cachedSegmentID = ResourceID(
        cacheKey: record.cacheKey,
        kind: .segment,
        resourceKey: ResourceID.makeResourceKey(from: "https://origin-a.example.com/seg-1.ts")
    )
    let payload = Data("cached-segment-payload".utf8)
    _ = try coreCache.write(payload, resource: cachedSegmentID, at: 0)
    _ = try coreCache.finalizeWrite(resource: cachedSegmentID, expectedLength: Int64(payload.count))

    let infoBefore = try facade.cacheInfo(alias: "MDROT")
    #expect(infoBefore.totalBytesOnDisk >= Int64(payload.count))
    #expect(infoBefore.cacheKey == record.cacheKey)

    let rotatedRemoteURL = try #require(URL(string: "https://origin-b.example.com/master.m3u8"))
    let updated = try facade.updateRemoteURL(alias: "MDROT", remoteURL: rotatedRemoteURL)
    #expect(updated.cacheKey == record.cacheKey)
    #expect(updated.currentRemoteURL == rotatedRemoteURL)

    let proxyAfter = try facade.proxyURL(for: "MDROT")
    #expect(proxyAfter == proxyBefore)

    let fullRange = try #require(ByteRange(start: 0, endExclusive: Int64(payload.count)))
    let restoredPayload = try coreCache.read(resource: cachedSegmentID, range: fullRange)
    #expect(restoredPayload == payload)

    let infoAfter = try facade.cacheInfo(alias: "MDROT")
    #expect(infoAfter.cacheKey == record.cacheKey)
    #expect(infoAfter.currentRemoteURL == rotatedRemoteURL)
    #expect(infoAfter.totalBytesOnDisk >= Int64(payload.count))
}

@Test func facade_updateRemoteURL_emitsRotationPolicyMetadataForContinuityDebugging() throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-rotation-policy-logging")
    defer { try? FileManager.default.removeItem(at: directory) }

    let logger = RecordingStructuredLogger()
    let facade = HLSCacheFacade(baseDirectory: directory, logger: logger.logger)
    _ = try facade.register(
        alias: "MDROTL",
        assetID: "asset-rotation-logging",
        remoteURL: try #require(URL(string: "https://origin-a.example.com/master.m3u8"))
    )

    _ = try facade.updateRemoteURL(
        alias: "MDROTL",
        remoteURL: try #require(URL(string: "https://origin-b.example.com/master.m3u8"))
    )

    let event = try #require(
        logger.events().first { $0.operation == "updateRemoteURL" }
    )
    #expect(event.level == .info)
}

@Test func facade_updateRemoteURL_crossOriginRotation_missesNewURLsButPreservesPerURLCacheContinuity() async throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-rotation-policy-e2e")
    defer { try? FileManager.default.removeItem(at: directory) }

    let oldPlaylistURL = try #require(URL(string: "https://origin-a.example.com/hls/media.m3u8"))
    let newPlaylistURL = try #require(URL(string: "https://origin-b.example.com/hls/media.m3u8"))
    let oldSegmentURL = try #require(URL(string: "https://origin-a.example.com/hls/seg-1.ts"))
    let newSegmentURL = try #require(URL(string: "https://origin-b.example.com/hls/seg-1.ts"))
    let oldKeyURL = try #require(URL(string: "https://origin-a.example.com/hls/keys/enc.key"))
    let newKeyURL = try #require(URL(string: "https://origin-b.example.com/hls/keys/enc.key"))

    let oldPlaylistPayload = Data("#EXTM3U\n#EXT-X-ENDLIST\n".utf8)
    let newPlaylistPayload = Data("#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-ENDLIST\n".utf8)
    let oldSegmentPayload = Data((0..<12).map { UInt8($0) })
    let newSegmentPayload = Data((100..<112).map { UInt8($0) })
    let oldKeyPayload = Data([1, 2, 3, 4, 5, 6])
    let newKeyPayload = Data([9, 8, 7, 6, 5, 4])
    let originRequestCounter = OriginRequestCounter()

    let originHeaders = ["X-Origin-Token": "token-rotation-1"]
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [RotationContinuityOriginURLProtocol.self]
    let originSession = URLSession(configuration: sessionConfiguration)

    RotationContinuityOriginURLProtocol.setHandler { request in
        #expect(request.value(forHTTPHeaderField: "X-Origin-Token") == originHeaders["X-Origin-Token"])
        let url = try #require(request.url)
        let method = (request.httpMethod ?? "GET").uppercased()
        originRequestCounter.record(method: method, url: url)

        let payload: Data
        let contentType: String
        switch url {
        case oldPlaylistURL:
            payload = oldPlaylistPayload
            contentType = "application/vnd.apple.mpegurl"
        case newPlaylistURL:
            payload = newPlaylistPayload
            contentType = "application/vnd.apple.mpegurl"
        case oldSegmentURL:
            payload = oldSegmentPayload
            contentType = "video/mp2t"
        case newSegmentURL:
            payload = newSegmentPayload
            contentType = "video/mp2t"
        case oldKeyURL:
            payload = oldKeyPayload
            contentType = "application/octet-stream"
        case newKeyURL:
            payload = newKeyPayload
            contentType = "application/octet-stream"
        default:
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: 404,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Length": "0"]
                )
            )
            return (response, Data())
        }

        if method == "HEAD" {
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Length": String(payload.count),
                        "Content-Type": contentType
                    ]
                )
            )
            return (response, Data())
        }

        let totalLength = Int64(payload.count)
        let rangeValue = request.value(forHTTPHeaderField: "Range")
        let parsedRange = rangeValue.flatMap { ByteRange.parseHTTPRange($0, totalLength: totalLength) }
            ?? ByteRange(start: 0, endExclusive: totalLength)
        let range = try #require(parsedRange)
        let start = Int(range.start)
        let endExclusive = Int(range.endExclusive)
        let slice = Data(payload[start..<endExclusive])
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": String(slice.count),
                    "Content-Range": "bytes \(range.start)-\(range.endExclusive - 1)/\(payload.count)",
                    "Content-Type": contentType
                ]
            )
        )
        return (response, slice)
    }
    defer { RotationContinuityOriginURLProtocol.resetHandler() }

    let facade = HLSCacheFacade(baseDirectory: directory, networkSession: originSession)
    _ = try facade.register(
        alias: "MDROT2",
        assetID: "asset-rotation-policy",
        remoteURL: oldPlaylistURL,
        headers: originHeaders
    )
    _ = try facade.startServer(host: "127.0.0.1", port: 0)
    defer { facade.stopServer() }

    let proxySession = URLSession(configuration: .ephemeral)
    let oldPlaylistProxyURL = try facade.proxyURL(for: "MDROT2", kind: .raw, remoteURL: oldPlaylistURL)
    let oldSegmentProxyURL = try facade.proxyURL(for: "MDROT2", kind: .segment, remoteURL: oldSegmentURL)
    let oldKeyProxyURL = try facade.proxyURL(for: "MDROT2", kind: .key, remoteURL: oldKeyURL)

    let (oldPlaylistData, oldPlaylistResponse) = try await proxySession.data(from: oldPlaylistProxyURL)
    let oldPlaylistHTTP = try #require(oldPlaylistResponse as? HTTPURLResponse)
    #expect(oldPlaylistHTTP.statusCode == 200)
    #expect(oldPlaylistData == oldPlaylistPayload)

    let (oldSegmentData, oldSegmentResponse) = try await proxySession.data(from: oldSegmentProxyURL)
    let oldSegmentHTTP = try #require(oldSegmentResponse as? HTTPURLResponse)
    #expect(oldSegmentHTTP.statusCode == 200)
    #expect(oldSegmentData == oldSegmentPayload)

    let (oldKeyData, oldKeyResponse) = try await proxySession.data(from: oldKeyProxyURL)
    let oldKeyHTTP = try #require(oldKeyResponse as? HTTPURLResponse)
    #expect(oldKeyHTTP.statusCode == 200)
    #expect(oldKeyData == oldKeyPayload)

    let oldPlaylistOriginCountAfterFirstFetch = originRequestCounter.totalRequests(for: oldPlaylistURL)
    let oldSegmentOriginCountAfterFirstFetch = originRequestCounter.totalRequests(for: oldSegmentURL)
    let oldKeyOriginCountAfterFirstFetch = originRequestCounter.totalRequests(for: oldKeyURL)
    #expect(oldPlaylistOriginCountAfterFirstFetch >= 1)
    #expect(oldSegmentOriginCountAfterFirstFetch >= 1)
    #expect(oldKeyOriginCountAfterFirstFetch >= 1)

    _ = try facade.updateRemoteURL(alias: "MDROT2", remoteURL: newPlaylistURL)

    let newPlaylistProxyURL = try facade.proxyURL(for: "MDROT2", kind: .raw, remoteURL: newPlaylistURL)
    let newSegmentProxyURL = try facade.proxyURL(for: "MDROT2", kind: .segment, remoteURL: newSegmentURL)
    let newKeyProxyURL = try facade.proxyURL(for: "MDROT2", kind: .key, remoteURL: newKeyURL)

    let (newPlaylistData, newPlaylistResponse) = try await proxySession.data(from: newPlaylistProxyURL)
    let newPlaylistHTTP = try #require(newPlaylistResponse as? HTTPURLResponse)
    #expect(newPlaylistHTTP.statusCode == 200)
    #expect(newPlaylistData == newPlaylistPayload)

    let (newSegmentData, newSegmentResponse) = try await proxySession.data(from: newSegmentProxyURL)
    let newSegmentHTTP = try #require(newSegmentResponse as? HTTPURLResponse)
    #expect(newSegmentHTTP.statusCode == 200)
    #expect(newSegmentData == newSegmentPayload)

    let (newKeyData, newKeyResponse) = try await proxySession.data(from: newKeyProxyURL)
    let newKeyHTTP = try #require(newKeyResponse as? HTTPURLResponse)
    #expect(newKeyHTTP.statusCode == 200)
    #expect(newKeyData == newKeyPayload)

    let newPlaylistOriginCountAfterFirstFetch = originRequestCounter.totalRequests(for: newPlaylistURL)
    let newSegmentOriginCountAfterFirstFetch = originRequestCounter.totalRequests(for: newSegmentURL)
    let newKeyOriginCountAfterFirstFetch = originRequestCounter.totalRequests(for: newKeyURL)
    #expect(newPlaylistOriginCountAfterFirstFetch >= 1)
    #expect(newSegmentOriginCountAfterFirstFetch >= 1)
    #expect(newKeyOriginCountAfterFirstFetch >= 1)

    let (secondNewPlaylistData, _) = try await proxySession.data(from: newPlaylistProxyURL)
    let (secondNewSegmentData, _) = try await proxySession.data(from: newSegmentProxyURL)
    let (secondNewKeyData, _) = try await proxySession.data(from: newKeyProxyURL)
    #expect(secondNewPlaylistData == newPlaylistPayload)
    #expect(secondNewSegmentData == newSegmentPayload)
    #expect(secondNewKeyData == newKeyPayload)
    #expect(originRequestCounter.totalRequests(for: newPlaylistURL) == newPlaylistOriginCountAfterFirstFetch)
    #expect(originRequestCounter.totalRequests(for: newSegmentURL) == newSegmentOriginCountAfterFirstFetch)
    #expect(originRequestCounter.totalRequests(for: newKeyURL) == newKeyOriginCountAfterFirstFetch)

    let (oldSegmentAfterRotation, _) = try await proxySession.data(from: oldSegmentProxyURL)
    let (oldKeyAfterRotation, _) = try await proxySession.data(from: oldKeyProxyURL)
    #expect(oldSegmentAfterRotation == oldSegmentPayload)
    #expect(oldKeyAfterRotation == oldKeyPayload)
    #expect(originRequestCounter.totalRequests(for: oldPlaylistURL) == oldPlaylistOriginCountAfterFirstFetch)
    #expect(originRequestCounter.totalRequests(for: oldSegmentURL) == oldSegmentOriginCountAfterFirstFetch)
    #expect(originRequestCounter.totalRequests(for: oldKeyURL) == oldKeyOriginCountAfterFirstFetch)
}

@Test func facade_proxyRuntime_legacyResourceKeyFallback_reusesCachedBytesWithoutOriginFetch() async throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-legacy-resource-key-fallback")
    defer { try? FileManager.default.removeItem(at: directory) }

    let playlistURL = try #require(URL(string: "https://origin.example.com/hls/master.m3u8"))
    let segmentURL = try #require(URL(string: "https://origin.example.com/hls/seg.ts?b=2&a=1"))
    let payload = Data((0..<16).map { UInt8($0 + 10) })
    let originRequestCounter = OriginRequestCounter()

    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [LegacyFallbackOriginURLProtocol.self]
    let originSession = URLSession(configuration: sessionConfiguration)

    LegacyFallbackOriginURLProtocol.setHandler { request in
        let url = try #require(request.url)
        let method = (request.httpMethod ?? "GET").uppercased()
        originRequestCounter.record(method: method, url: url)

        if method == "HEAD" {
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Length": String(payload.count),
                        "Content-Type": "video/mp2t"
                    ]
                )
            )
            return (response, Data())
        }

        let totalLength = Int64(payload.count)
        let rangeHeader = request.value(forHTTPHeaderField: "Range")
        let parsedRange = rangeHeader.flatMap { ByteRange.parseHTTPRange($0, totalLength: totalLength) }
            ?? ByteRange(start: 0, endExclusive: totalLength)
        let range = try #require(parsedRange)
        let start = Int(range.start)
        let endExclusive = Int(range.endExclusive)
        let slice = Data(payload[start..<endExclusive])
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: rangeHeader == nil ? 200 : 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": String(slice.count),
                    "Content-Type": "video/mp2t",
                    "Content-Range": "bytes \(range.start)-\(range.endExclusive - 1)/\(payload.count)"
                ]
            )
        )
        return (response, slice)
    }
    defer { LegacyFallbackOriginURLProtocol.resetHandler() }

    let logger = RecordingStructuredLogger()
    let facade = HLSCacheFacade(baseDirectory: directory, logger: logger.logger, networkSession: originSession)
    let record = try facade.register(
        alias: "MDLEGACY",
        assetID: "asset-legacy-fallback",
        remoteURL: playlistURL
    )

    do {
        let cache = try CoreCache(baseDirectory: directory)
        let legacyResourceID = ResourceID(
            cacheKey: record.cacheKey,
            kind: .segment,
            resourceKey: ResourceID.makeResourceKey(from: segmentURL.absoluteString)
        )
        _ = try cache.write(
            payload,
            resource: legacyResourceID,
            at: 0,
            contentType: "video/mp2t",
            expectedLength: Int64(payload.count)
        )
        _ = try cache.finalizeWrite(resource: legacyResourceID, expectedLength: Int64(payload.count))
    }

    _ = try facade.startServer(host: "127.0.0.1", port: 0)
    defer { facade.stopServer() }

    let proxyURL = try facade.proxyURL(for: "MDLEGACY", kind: .segment, remoteURL: segmentURL)
    let proxySession = URLSession(configuration: .ephemeral)
    let (data, response) = try await proxySession.data(from: proxyURL)
    let httpResponse = try #require(response as? HTTPURLResponse)
    #expect(httpResponse.statusCode == 200)
    #expect(data == payload)
    #expect(originRequestCounter.totalRequests(for: segmentURL) == 0)

}

@Test func facade_proxyRouting_buildAndDecode_roundTripsEncodedRemoteURL() throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-proxy-routing")
    defer { try? FileManager.default.removeItem(at: directory) }

    let facade = HLSCacheFacade(baseDirectory: directory)
    _ = try facade.register(
        alias: "MD0534",
        assetID: "asset-0534",
        remoteURL: try #require(URL(string: "https://cdn.example.com/master.m3u8"))
    )
    _ = try facade.startServer(port: 0)

    let remoteURL = try #require(URL(string: "https://cdn.example.com/video/seg.ts?token=a/b==&part=1"))
    let proxyURL = try facade.proxyURL(for: "MD0534", kind: .segment, remoteURL: remoteURL)
    #expect(proxyURL.absoluteString.contains("/MD0534/seg/"))

    let decoded = try facade.decodeProxyRequestURL(proxyURL)
    #expect(decoded.alias == "MD0534")
    #expect(decoded.kind == .segment)
    #expect(decoded.remoteURL.absoluteString == remoteURL.absoluteString)
}

@Test func facade_decodeProxyRequestURL_unknownAlias_throwsAliasNotFound() throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-proxy-routing-missing")
    defer { try? FileManager.default.removeItem(at: directory) }

    let facade = HLSCacheFacade(baseDirectory: directory)
    let baseURL = try facade.startServer(port: 0)
    let requestURL = try #require(
        URL(string: "\(baseURL.absoluteString)/MISSING/seg/https%3A%2F%2Fcdn.example.com%2Fv.ts")
    )

    do {
        _ = try facade.decodeProxyRequestURL(requestURL)
        #expect(Bool(false))
    } catch let error as HLSCacheError {
        #expect(error == .aliasNotFound("MISSING"))
    }
}

@Test func facade_structuredLogging_emitsLifecycleEvents() throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-logging")
    defer { try? FileManager.default.removeItem(at: directory) }

    let facade = HLSCacheFacade(baseDirectory: directory)

    _ = try facade.startServer(port: 0)
    _ = try facade.register(
        alias: "MDLOG",
        assetID: "asset-log",
        remoteURL: try #require(URL(string: "https://cdn.example.com/log.m3u8"))
    )
    _ = try facade.proxyURL(for: "MDLOG")
    _ = try facade.cacheInfo(alias: "MDLOG")

}

@Test func facade_proxyRuntime_propagatesCorrelationIDAcrossProxyAndCoreLogs() async throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-correlation-propagation")
    defer { try? FileManager.default.removeItem(at: directory) }

    let rootRemoteURL = try #require(URL(string: "https://origin.example.com/hls/root.m3u8"))
    let segmentRemoteURL = try #require(URL(string: "https://origin.example.com/hls/seg-trace.ts"))
    let payload = Data((0..<24).map { UInt8($0 + 1) })

    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [CorrelationTraceOriginURLProtocol.self]
    let originSession = URLSession(configuration: sessionConfiguration)

    CorrelationTraceOriginURLProtocol.setHandler { request in
        let url = try #require(request.url)
        #expect(url == segmentRemoteURL)
        let method = (request.httpMethod ?? "GET").uppercased()

        if method == "HEAD" {
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Length": String(payload.count),
                        "Content-Type": "video/mp2t"
                    ]
                )
            )
            return (response, Data())
        }

        let totalLength = Int64(payload.count)
        let rangeHeader = request.value(forHTTPHeaderField: "Range")
        let parsedRange = rangeHeader.flatMap { ByteRange.parseHTTPRange($0, totalLength: totalLength) }
            ?? ByteRange(start: 0, endExclusive: totalLength)
        let range = try #require(parsedRange)
        let start = Int(range.start)
        let endExclusive = Int(range.endExclusive)
        let slice = Data(payload[start..<endExclusive])

        var headers: [String: String] = [
            "Content-Length": String(slice.count),
            "Content-Type": "video/mp2t"
        ]
        let statusCode: Int
        if rangeHeader == nil {
            statusCode = 200
        } else {
            statusCode = 206
            headers["Content-Range"] = "bytes \(range.start)-\(range.endExclusive - 1)/\(payload.count)"
        }

        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )
        )
        return (response, slice)
    }
    defer { CorrelationTraceOriginURLProtocol.resetHandler() }

    let logger = RecordingStructuredLogger()
    let facade = HLSCacheFacade(baseDirectory: directory, logger: logger.logger, networkSession: originSession)
    _ = try facade.register(alias: "MDTRACE", assetID: "asset-trace", remoteURL: rootRemoteURL)
    _ = try facade.startServer(host: "127.0.0.1", port: 0)
    defer { facade.stopServer() }

    let proxyURL = try facade.proxyURL(for: "MDTRACE", kind: .segment, remoteURL: segmentRemoteURL)
    let proxySession = URLSession(configuration: .ephemeral)
    let (data, response) = try await proxySession.data(from: proxyURL)
    let httpResponse = try #require(response as? HTTPURLResponse)
    #expect(httpResponse.statusCode == 200)
    #expect(data == payload)

    let events = logger.events()
    _ = try #require(
        events.first {
            $0.operation == "proxyRequest"
        }
    )

    var correlatedOperations = Set(events.map(\.operation))
    if !correlatedOperations.contains("finalizeWrite") {
        for _ in 0..<50 {
            usleep(20_000)
            let refreshed = logger.events()
            correlatedOperations = Set(refreshed.map(\.operation))
            if correlatedOperations.contains("finalizeWrite") {
                break
            }
        }
    }
    #expect(correlatedOperations.contains("plan"))
    #expect(correlatedOperations.contains("write"))
    #expect(correlatedOperations.contains("finalizeWrite"))
}

@Test func facade_initialization_passesLoggerToAliasRegistryRecoveryTelemetry() throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-alias-registry-recovery")
    defer { try? FileManager.default.removeItem(at: directory) }

    let registryFileURL = directory.appendingPathComponent("alias_registry.json")
    try Data("{bad-json".utf8).write(to: registryFileURL)

    let logger = RecordingStructuredLogger()
    _ = HLSCacheFacade(baseDirectory: directory, logger: logger.logger)

    let event = try #require(
        logger.events().first {
            $0.operation == "loadAliasRegistry"

        }
    )
    #expect(event.level == .warning)
}

@Test func facade_cacheInfoAndClearCache_reflectsUnderlyingDiskUsage() throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-info")
    defer { try? FileManager.default.removeItem(at: directory) }

    let facade = HLSCacheFacade(baseDirectory: directory)
    let record = try facade.register(
        alias: "MD1000",
        assetID: "asset-1000",
        remoteURL: try #require(URL(string: "https://cdn.example.com/video.m3u8"))
    )

    // Seed cache bytes via CoreCache to validate cacheInfo/clearCache facade behavior.
    let coreCache = try CoreCache(baseDirectory: directory)
    let resource = makeResourceID(cacheKey: record.cacheKey, key: "segment-1")
    _ = try coreCache.write(Data(repeating: 1, count: 1024), resource: resource, at: 0)
    _ = try coreCache.finalizeWrite(resource: resource, expectedLength: 1024)

    let before = try facade.cacheInfo(alias: "MD1000")
    #expect(before.totalBytesOnDisk >= 1024)

    try facade.clearCache(alias: "MD1000")

    let after = try facade.cacheInfo(alias: "MD1000")
    #expect(after.totalBytesOnDisk == 0)
}

@Test func facade_removeAliasAndRemoveAllAliases_updateRegistryState() throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-remove-alias")
    defer { try? FileManager.default.removeItem(at: directory) }

    let facade = HLSCacheFacade(baseDirectory: directory)
    _ = try facade.register(
        alias: "MDRM1",
        assetID: "asset-rm-1",
        remoteURL: try #require(URL(string: "https://cdn.example.com/remove-1.m3u8"))
    )
    _ = try facade.register(
        alias: "MDRM2",
        assetID: "asset-rm-2",
        remoteURL: try #require(URL(string: "https://cdn.example.com/remove-2.m3u8"))
    )

    _ = try facade.removeAlias(alias: "MDRM1")
    #expect(facade.listAliases().map(\.alias) == ["MDRM2"])

    let removedCount = try facade.removeAllAliases()
    #expect(removedCount == 1)
    #expect(facade.listAliases().isEmpty)
}

@Test func facade_setPluginsAndStopServer_behavesAsExpected() throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-plugins")
    defer { try? FileManager.default.removeItem(at: directory) }

    let facade = HLSCacheFacade(baseDirectory: directory)
    _ = try facade.startServer(port: 0)

    let applied = facade.setPlugins([
        TestPlugin(id: "noop", version: "1.0.0"),
        TestPlugin(id: "checksum", version: "2.1.0")
    ])

    #expect(applied.count == 2)
    #expect(applied[0] == PluginStamp(id: "noop", version: "1.0.0"))
    #expect(facade.activePlugins().count == 2)

    facade.stopServer()

    do {
        _ = try facade.proxyURL(for: "missing")
        #expect(Bool(false))
    } catch let error as HLSCacheError {
        #expect(error == .serverNotRunning)
    }
}

@Test func noopPlugin_defaultsAndSetPlugins_recordsExpectedStamp() throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-noop")
    defer { try? FileManager.default.removeItem(at: directory) }

    let facade = HLSCacheFacade(baseDirectory: directory)
    let plugin = NoopPlugin()

    #expect(plugin.id == "noop")
    #expect(plugin.version == "1.0.0")

    let applied = facade.setPlugins([plugin])
    #expect(applied == [PluginStamp(id: "noop", version: "1.0.0")])
}

@Test func facade_proxyRuntime_healthEndpoint_reachableWhileRunning_thenUnavailableAfterStop() async throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-runtime-health")
    defer { try? FileManager.default.removeItem(at: directory) }

    let facade = HLSCacheFacade(baseDirectory: directory)
    let baseURL = try facade.startServer(host: "127.0.0.1", port: 0)
    let healthURL = baseURL.appendingPathComponent("health")
    let session = URLSession(configuration: .ephemeral)

    let (runningData, runningResponse) = try await session.data(from: healthURL)
    let runningHTTPResponse = try #require(runningResponse as? HTTPURLResponse)
    #expect(runningHTTPResponse.statusCode == 200)
    #expect(String(data: runningData, encoding: .utf8) == "ok\n")

    facade.stopServer()

    do {
        _ = try await session.data(from: healthURL)
        #expect(Bool(false))
    } catch let error as URLError {
        let expectedCodes: Set<URLError.Code> = [.cannotConnectToHost, .networkConnectionLost]
        #expect(expectedCodes.contains(error.code))
    }
}

@Test func facade_startServer_portCollision_returnsTypedStartupError() throws {
    let baseDirectory = try makeHLSCacheTempDirectory(prefix: "hlscache-runtime-collision")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let firstFacade = HLSCacheFacade(baseDirectory: baseDirectory.appendingPathComponent("a"))
    let secondFacade = HLSCacheFacade(baseDirectory: baseDirectory.appendingPathComponent("b"))

    let firstURL = try firstFacade.startServer(host: "127.0.0.1", port: 0)
    defer { firstFacade.stopServer() }

    let occupiedPort = try #require(firstURL.port)
    do {
        _ = try secondFacade.startServer(host: "127.0.0.1", port: occupiedPort)
        #expect(Bool(false))
    } catch let error as ProxyServerRuntimeError {
        switch error {
        case let .listenerBindFailed(host, port, reason):
            #expect(host == "127.0.0.1")
            #expect(port == occupiedPort)
            #expect(!reason.isEmpty)
        case .listenerStartupTimedOut:
            #expect(Bool(true))
        default:
            #expect(Bool(false))
        }
    }
}

@Test func facade_proxyRuntime_servesRawAndKeyRoutes_overLocalhostTransport() async throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-runtime-routes")
    defer { try? FileManager.default.removeItem(at: directory) }

    let rawRemoteURL = try #require(URL(string: "https://origin.example.com/video/movie.mp4"))
    let keyRemoteURL = try #require(URL(string: "https://origin.example.com/keys/enc.key"))
    let rawPayload = Data((0..<32).map { UInt8($0) })
    let keyPayload = Data([9, 8, 7, 6, 5, 4, 3, 2])
    let originRequestCounter = OriginRequestCounter()

    let originHeaders = ["X-Origin-Token": "token-123"]
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [ProxyRuntimeOriginURLProtocol.self]
    let originSession = URLSession(configuration: sessionConfiguration)

    ProxyRuntimeOriginURLProtocol.setHandler { request in
        #expect(request.value(forHTTPHeaderField: "X-Origin-Token") == originHeaders["X-Origin-Token"])
        let url = try #require(request.url)
        let method = (request.httpMethod ?? "GET").uppercased()
        originRequestCounter.record(method: method, url: url)

        let payload: Data
        let contentType: String
        switch url {
        case rawRemoteURL:
            payload = rawPayload
            contentType = "video/mp4"
        case keyRemoteURL:
            payload = keyPayload
            contentType = "application/octet-stream"
        default:
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: 404,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Length": "0"]
                )
            )
            return (response, Data())
        }

        if method == "HEAD" {
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Length": String(payload.count),
                        "Content-Type": contentType
                    ]
                )
            )
            return (response, Data())
        }

        let totalLength = Int64(payload.count)
        let rangeValue = request.value(forHTTPHeaderField: "Range")
        let parsedRange = rangeValue.flatMap { ByteRange.parseHTTPRange($0, totalLength: totalLength) }
            ?? ByteRange(start: 0, endExclusive: totalLength)
        let range = try #require(parsedRange)
        let start = Int(range.start)
        let endExclusive = Int(range.endExclusive)
        let slice = Data(payload[start..<endExclusive])
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": String(slice.count),
                    "Content-Range": "bytes \(range.start)-\(range.endExclusive - 1)/\(payload.count)",
                    "Content-Type": contentType
                ]
            )
        )
        return (response, slice)
    }
    defer { ProxyRuntimeOriginURLProtocol.resetHandler() }

    let logger = RecordingStructuredLogger()
    let facade = HLSCacheFacade(baseDirectory: directory, logger: logger.logger, networkSession: originSession)
    _ = try facade.register(
        alias: "MDRUNTIME",
        assetID: "asset-runtime",
        remoteURL: rawRemoteURL,
        headers: originHeaders
    )
    _ = try facade.startServer(host: "127.0.0.1", port: 0)
    defer { facade.stopServer() }

    let proxySession = URLSession(configuration: .ephemeral)
    let rawProxyURL = try facade.proxyURL(for: "MDRUNTIME", kind: .raw, remoteURL: rawRemoteURL)
    let (rawData, rawResponse) = try await proxySession.data(from: rawProxyURL)
    let rawHTTPResponse = try #require(rawResponse as? HTTPURLResponse)
    #expect(rawHTTPResponse.statusCode == 200)
    #expect(rawHTTPResponse.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
    #expect(rawHTTPResponse.value(forHTTPHeaderField: "Content-Length") == String(rawPayload.count))
    #expect(rawData == rawPayload)
    let rawOriginRequestsAfterFirstGET = originRequestCounter.totalRequests(for: rawRemoteURL)
    #expect(rawOriginRequestsAfterFirstGET >= 1)

    let (secondRawData, secondRawResponse) = try await proxySession.data(from: rawProxyURL)
    let secondRawHTTPResponse = try #require(secondRawResponse as? HTTPURLResponse)
    #expect(secondRawHTTPResponse.statusCode == 200)
    #expect(secondRawHTTPResponse.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
    #expect(secondRawHTTPResponse.value(forHTTPHeaderField: "Content-Length") == String(rawPayload.count))
    #expect(secondRawData == rawPayload)

    var rawHeadRequest = URLRequest(url: rawProxyURL)
    rawHeadRequest.httpMethod = "HEAD"
    let (rawHeadData, rawHeadResponse) = try await proxySession.data(for: rawHeadRequest)
    let rawHeadHTTPResponse = try #require(rawHeadResponse as? HTTPURLResponse)
    #expect(rawHeadHTTPResponse.statusCode == 200)
    #expect(rawHeadHTTPResponse.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
    #expect(rawHeadHTTPResponse.value(forHTTPHeaderField: "Content-Length") == String(rawPayload.count))
    #expect(rawHeadData.isEmpty)

    let rawOriginRequestsAfterCacheHitAndHEAD = originRequestCounter.totalRequests(for: rawRemoteURL)
    #expect(rawOriginRequestsAfterCacheHitAndHEAD == rawOriginRequestsAfterFirstGET)

    let keyProxyURL = try facade.proxyURL(for: "MDRUNTIME", kind: .key, remoteURL: keyRemoteURL)
    var keyRequest = URLRequest(url: keyProxyURL)
    keyRequest.httpMethod = "GET"
    keyRequest.setValue("bytes=2-5", forHTTPHeaderField: "Range")

    let (keyData, keyResponse) = try await proxySession.data(for: keyRequest)
    let keyHTTPResponse = try #require(keyResponse as? HTTPURLResponse)
    #expect(keyHTTPResponse.statusCode == 206)
    #expect(keyHTTPResponse.value(forHTTPHeaderField: "Content-Range") == "bytes 2-5/\(keyPayload.count)")
    #expect(keyData == Data(keyPayload[2..<6]))
}

@Test func facade_proxyRuntime_servesRewrittenSegmentAndKeyRoutes_overLocalhostTransport() async throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-runtime-playback-routes")
    defer { try? FileManager.default.removeItem(at: directory) }

    let playlistURL = try #require(URL(string: "https://origin.example.com/hls/media.m3u8"))
    let segmentRemoteURL = try #require(URL(string: "https://origin.example.com/hls/seg-1.ts"))
    let keyRemoteURL = try #require(URL(string: "https://origin.example.com/hls/keys/enc.key"))
    let segmentPayload = Data((0..<16).map { UInt8($0 + 10) })
    let keyPayload = Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
    let originRequestCounter = OriginRequestCounter()

    let originHeaders = ["X-Origin-Token": "token-playback-1"]
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [RewrittenRouteOriginURLProtocol.self]
    let originSession = URLSession(configuration: sessionConfiguration)

    RewrittenRouteOriginURLProtocol.setHandler { request in
        #expect(request.value(forHTTPHeaderField: "X-Origin-Token") == originHeaders["X-Origin-Token"])
        let url = try #require(request.url)
        let method = (request.httpMethod ?? "GET").uppercased()
        originRequestCounter.record(method: method, url: url)

        let payload: Data
        let contentType: String
        switch url {
        case segmentRemoteURL:
            payload = segmentPayload
            contentType = "video/mp2t"
        case keyRemoteURL:
            payload = keyPayload
            contentType = "application/octet-stream"
        default:
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: 404,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Length": "0"]
                )
            )
            return (response, Data())
        }

        if method == "HEAD" {
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Length": String(payload.count),
                        "Content-Type": contentType
                    ]
                )
            )
            return (response, Data())
        }

        let totalLength = Int64(payload.count)
        let rangeValue = request.value(forHTTPHeaderField: "Range")
        let parsedRange = rangeValue.flatMap { ByteRange.parseHTTPRange($0, totalLength: totalLength) }
            ?? ByteRange(start: 0, endExclusive: totalLength)
        let range = try #require(parsedRange)
        let start = Int(range.start)
        let endExclusive = Int(range.endExclusive)
        let slice = Data(payload[start..<endExclusive])
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": String(slice.count),
                    "Content-Range": "bytes \(range.start)-\(range.endExclusive - 1)/\(payload.count)",
                    "Content-Type": contentType
                ]
            )
        )
        return (response, slice)
    }
    defer { RewrittenRouteOriginURLProtocol.resetHandler() }

    let logger = RecordingStructuredLogger()
    let facade = HLSCacheFacade(baseDirectory: directory, logger: logger.logger, networkSession: originSession)
    _ = try facade.register(
        alias: "MDPLAY",
        assetID: "asset-playback",
        remoteURL: playlistURL,
        headers: originHeaders
    )
    _ = try facade.startServer(host: "127.0.0.1", port: 0)
    defer { facade.stopServer() }

    let playlistFixture = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-KEY:METHOD=AES-128,URI="keys/enc.key"
    #EXTINF:4.0,
    seg-1.ts
    #EXT-X-ENDLIST
    """

    let rewrittenPlaylist = try HLSPlaylistRewriter.rewrite(
        playlistFixture,
        alias: "MDPLAY",
        playlistURL: playlistURL
    ) { alias, kind, remoteURL in
        try facade.proxyURL(for: alias, kind: kind, remoteURL: remoteURL)
    }

    let rewritten = HLSPlaylistParser.parse(rewrittenPlaylist, playlistURL: playlistURL)
    #expect(rewritten.segments.count == 1)
    #expect(rewritten.keys.count == 1)

    let segmentProxyURL = try #require(rewritten.segments.first?.remoteURL)
    let keyProxyURL = try #require(rewritten.keys.first?.remoteURL)

    let decodedSegmentRoute = try facade.decodeProxyRequestURL(segmentProxyURL)
    #expect(decodedSegmentRoute.kind == .segment)
    #expect(decodedSegmentRoute.remoteURL == segmentRemoteURL)

    let decodedKeyRoute = try facade.decodeProxyRequestURL(keyProxyURL)
    #expect(decodedKeyRoute.kind == .key)
    #expect(decodedKeyRoute.remoteURL == keyRemoteURL)

    let proxySession = URLSession(configuration: .ephemeral)

    let (firstSegmentData, firstSegmentResponse) = try await proxySession.data(from: segmentProxyURL)
    let firstSegmentHTTPResponse = try #require(firstSegmentResponse as? HTTPURLResponse)
    #expect(firstSegmentHTTPResponse.statusCode == 200)
    #expect(firstSegmentHTTPResponse.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
    #expect(firstSegmentHTTPResponse.value(forHTTPHeaderField: "Content-Length") == String(segmentPayload.count))
    #expect(firstSegmentData == segmentPayload)
    let segmentOriginRequestsAfterFirstGET = originRequestCounter.totalRequests(for: segmentRemoteURL)
    #expect(segmentOriginRequestsAfterFirstGET >= 1)

    let (secondSegmentData, secondSegmentResponse) = try await proxySession.data(from: segmentProxyURL)
    let secondSegmentHTTPResponse = try #require(secondSegmentResponse as? HTTPURLResponse)
    #expect(secondSegmentHTTPResponse.statusCode == 200)
    #expect(secondSegmentHTTPResponse.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
    #expect(secondSegmentHTTPResponse.value(forHTTPHeaderField: "Content-Length") == String(segmentPayload.count))
    #expect(secondSegmentData == segmentPayload)

    var segmentHeadRequest = URLRequest(url: segmentProxyURL)
    segmentHeadRequest.httpMethod = "HEAD"
    let (segmentHeadData, segmentHeadResponse) = try await proxySession.data(for: segmentHeadRequest)
    let segmentHeadHTTPResponse = try #require(segmentHeadResponse as? HTTPURLResponse)
    #expect(segmentHeadHTTPResponse.statusCode == 200)
    #expect(segmentHeadHTTPResponse.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
    #expect(segmentHeadHTTPResponse.value(forHTTPHeaderField: "Content-Length") == String(segmentPayload.count))
    #expect(segmentHeadData.isEmpty)
    let segmentOriginRequestsAfterCacheHitAndHEAD = originRequestCounter.totalRequests(for: segmentRemoteURL)
    #expect(segmentOriginRequestsAfterCacheHitAndHEAD == segmentOriginRequestsAfterFirstGET)

    let (firstKeyData, firstKeyResponse) = try await proxySession.data(from: keyProxyURL)
    let firstKeyHTTPResponse = try #require(firstKeyResponse as? HTTPURLResponse)
    #expect(firstKeyHTTPResponse.statusCode == 200)
    #expect(firstKeyHTTPResponse.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
    #expect(firstKeyHTTPResponse.value(forHTTPHeaderField: "Content-Length") == String(keyPayload.count))
    #expect(firstKeyData == keyPayload)
    let keyOriginRequestsAfterFirstGET = originRequestCounter.totalRequests(for: keyRemoteURL)
    #expect(keyOriginRequestsAfterFirstGET >= 1)

    let (secondKeyData, secondKeyResponse) = try await proxySession.data(from: keyProxyURL)
    let secondKeyHTTPResponse = try #require(secondKeyResponse as? HTTPURLResponse)
    #expect(secondKeyHTTPResponse.statusCode == 200)
    #expect(secondKeyHTTPResponse.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
    #expect(secondKeyHTTPResponse.value(forHTTPHeaderField: "Content-Length") == String(keyPayload.count))
    #expect(secondKeyData == keyPayload)

    var keyHeadRequest = URLRequest(url: keyProxyURL)
    keyHeadRequest.httpMethod = "HEAD"
    let (keyHeadData, keyHeadResponse) = try await proxySession.data(for: keyHeadRequest)
    let keyHeadHTTPResponse = try #require(keyHeadResponse as? HTTPURLResponse)
    #expect(keyHeadHTTPResponse.statusCode == 200)
    #expect(keyHeadHTTPResponse.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
    #expect(keyHeadHTTPResponse.value(forHTTPHeaderField: "Content-Length") == String(keyPayload.count))
    #expect(keyHeadData.isEmpty)
    let keyOriginRequestsAfterCacheHitAndHEAD = originRequestCounter.totalRequests(for: keyRemoteURL)
    #expect(keyOriginRequestsAfterCacheHitAndHEAD == keyOriginRequestsAfterFirstGET)
}

@Test func facade_proxyRuntime_streamingTransport_progressiveAcrossNetworkFillPartialHitAndCacheHit() async throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-runtime-streaming-transport")
    defer { try? FileManager.default.removeItem(at: directory) }

    let rootRemoteURL = try #require(URL(string: "https://origin.example.com/hls/root-streaming.m3u8"))
    let networkFillURL = try #require(URL(string: "https://origin.example.com/hls/seg-network-fill.ts"))
    let partialHitURL = try #require(URL(string: "https://origin.example.com/hls/seg-partial-hit.ts"))
    let payloadSize = 786_432 // 3 x 256 KiB to force multiple range fetches.
    let networkFillPayload = Data((0..<payloadSize).map { UInt8($0 % 251) })
    let partialHitPayload = Data((0..<payloadSize).map { UInt8(($0 + 37) % 251) })
    let originRequestCounter = OriginRequestCounter()

    let originHeaders = ["X-Origin-Token": "token-streaming-transport"]
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [StreamingTransportOriginURLProtocol.self]
    let originSession = URLSession(configuration: sessionConfiguration)

    StreamingTransportOriginURLProtocol.setHandler { request in
        #expect(request.value(forHTTPHeaderField: "X-Origin-Token") == originHeaders["X-Origin-Token"])
        let url = try #require(request.url)
        let method = (request.httpMethod ?? "GET").uppercased()
        originRequestCounter.record(method: method, url: url)

        let payload: Data
        switch url {
        case networkFillURL:
            payload = networkFillPayload
        case partialHitURL:
            payload = partialHitPayload
        default:
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: 404,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Length": "0"]
                )
            )
            return (response, Data())
        }

        if method == "HEAD" {
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Length": String(payload.count),
                        "Content-Type": "video/mp2t"
                    ]
                )
            )
            return (response, Data())
        }

        let totalLength = Int64(payload.count)
        let rangeValue = request.value(forHTTPHeaderField: "Range")
        let parsedRange = rangeValue.flatMap { ByteRange.parseHTTPRange($0, totalLength: totalLength) }
            ?? ByteRange(start: 0, endExclusive: totalLength)
        let range = try #require(parsedRange)
        usleep(600_000)
        let start = Int(range.start)
        let endExclusive = Int(range.endExclusive)
        let slice = Data(payload[start..<endExclusive])
        let statusCode = rangeValue == nil ? 200 : 206

        var headerFields: [String: String] = [
            "Content-Length": String(slice.count),
            "Content-Type": "video/mp2t"
        ]
        if statusCode == 206 {
            headerFields["Content-Range"] = "bytes \(range.start)-\(range.endExclusive - 1)/\(payload.count)"
        }

        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headerFields
            )
        )
        return (response, slice)
    }
    defer { StreamingTransportOriginURLProtocol.resetHandler() }

    let facade = HLSCacheFacade(baseDirectory: directory, networkSession: originSession)
    _ = try facade.register(
        alias: "MDSTREAM",
        assetID: "asset-streaming-transport",
        remoteURL: rootRemoteURL,
        headers: originHeaders
    )
    _ = try facade.startServer(host: "127.0.0.1", port: 0)
    defer { facade.stopServer() }

    let networkFillProxyURL = try facade.proxyURL(for: "MDSTREAM", kind: .segment, remoteURL: networkFillURL)
    let networkFillResult = try performStreamingProbeRequest(URLRequest(url: networkFillProxyURL))
    #expect(networkFillResult.response.statusCode == 200)
    #expect(networkFillResult.data == networkFillPayload)
    #expect(networkFillResult.firstBodyByteDelay < networkFillResult.totalDuration * 0.8)

    let originRequestsAfterNetworkFill = originRequestCounter.totalRequests(for: networkFillURL)
    #expect(originRequestsAfterNetworkFill >= 3)

    let cacheHitResult = try performStreamingProbeRequest(URLRequest(url: networkFillProxyURL))
    #expect(cacheHitResult.response.statusCode == 200)
    #expect(cacheHitResult.data == networkFillPayload)
    #expect(originRequestCounter.totalRequests(for: networkFillURL) == originRequestsAfterNetworkFill)
    #expect(cacheHitResult.firstBodyByteDelay < cacheHitResult.totalDuration * 0.8)

    let partialHitProxyURL = try facade.proxyURL(for: "MDSTREAM", kind: .segment, remoteURL: partialHitURL)
    var seedRequest = URLRequest(url: partialHitProxyURL)
    seedRequest.setValue("bytes=0-262143", forHTTPHeaderField: "Range")
    let partialSeedResult = try performStreamingProbeRequest(seedRequest)
    #expect(partialSeedResult.response.statusCode == 206)
    #expect(partialSeedResult.data == Data(partialHitPayload[0..<262_144]))

    let originRequestsAfterPartialSeed = originRequestCounter.totalRequests(for: partialHitURL)

    let partialHitResult = try performStreamingProbeRequest(URLRequest(url: partialHitProxyURL))
    #expect(partialHitResult.response.statusCode == 200)
    #expect(partialHitResult.data == partialHitPayload)
    #expect(originRequestCounter.totalRequests(for: partialHitURL) > originRequestsAfterPartialSeed)
    #expect(partialHitResult.firstBodyByteDelay < partialHitResult.totalDuration * 0.7)
}

@Test func facade_proxyRuntime_offlineMode_servesCachedDataAndFailsCacheMissWithoutNetworkFallback() async throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-runtime-offline-transport")
    defer { try? FileManager.default.removeItem(at: directory) }

    let rootRemoteURL = try #require(URL(string: "https://origin.example.com/hls/root.m3u8"))
    let cachedSegmentURL = try #require(URL(string: "https://origin.example.com/hls/seg-cached.ts"))
    let uncachedSegmentURL = try #require(URL(string: "https://origin.example.com/hls/seg-uncached.ts"))

    let cachedPayload = Data((0..<20).map { UInt8($0 + 20) })
    let uncachedPayload = Data((100..<120).map { UInt8($0) })
    let originRequestCounter = OriginRequestCounter()

    let originHeaders = ["X-Origin-Token": "token-offline-transport"]
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [OfflineModeOriginURLProtocol.self]
    let originSession = URLSession(configuration: sessionConfiguration)

    OfflineModeOriginURLProtocol.setHandler { request in
        #expect(request.value(forHTTPHeaderField: "X-Origin-Token") == originHeaders["X-Origin-Token"])
        let url = try #require(request.url)
        let method = (request.httpMethod ?? "GET").uppercased()
        originRequestCounter.record(method: method, url: url)

        let payload: Data
        let contentType: String
        switch url {
        case cachedSegmentURL:
            payload = cachedPayload
            contentType = "video/mp2t"
        case uncachedSegmentURL:
            payload = uncachedPayload
            contentType = "video/mp2t"
        default:
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: 404,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Length": "0"]
                )
            )
            return (response, Data())
        }

        if method == "HEAD" {
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Length": String(payload.count),
                        "Content-Type": contentType
                    ]
                )
            )
            return (response, Data())
        }

        let totalLength = Int64(payload.count)
        let rangeValue = request.value(forHTTPHeaderField: "Range")
        let parsedRange = rangeValue.flatMap { ByteRange.parseHTTPRange($0, totalLength: totalLength) }
            ?? ByteRange(start: 0, endExclusive: totalLength)
        let range = try #require(parsedRange)
        let start = Int(range.start)
        let endExclusive = Int(range.endExclusive)
        let slice = Data(payload[start..<endExclusive])
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": String(slice.count),
                    "Content-Range": "bytes \(range.start)-\(range.endExclusive - 1)/\(payload.count)",
                    "Content-Type": contentType
                ]
            )
        )
        return (response, slice)
    }
    defer { OfflineModeOriginURLProtocol.resetHandler() }

    let logger = RecordingStructuredLogger()
    let facade = HLSCacheFacade(baseDirectory: directory, logger: logger.logger, networkSession: originSession)
    _ = try facade.register(
        alias: "MDOFFLINE",
        assetID: "asset-offline",
        remoteURL: rootRemoteURL,
        headers: originHeaders
    )
    _ = try facade.startServer(host: "127.0.0.1", port: 0)
    defer { facade.stopServer() }

    let proxySession = URLSession(configuration: .ephemeral)
    let cachedProxyURL = try facade.proxyURL(for: "MDOFFLINE", kind: .segment, remoteURL: cachedSegmentURL)

    let (firstCachedData, firstCachedResponse) = try await proxySession.data(from: cachedProxyURL)
    let firstCachedHTTPResponse = try #require(firstCachedResponse as? HTTPURLResponse)
    #expect(firstCachedHTTPResponse.statusCode == 200)
    #expect(firstCachedData == cachedPayload)
    let cachedOriginRequestsAfterWarmup = originRequestCounter.totalRequests(for: cachedSegmentURL)
    #expect(cachedOriginRequestsAfterWarmup >= 1)

    let offlineEnabled = facade.setOfflinePlaybackMode(enabled: true)
    #expect(offlineEnabled == true)

    let (secondCachedData, secondCachedResponse) = try await proxySession.data(from: cachedProxyURL)
    let secondCachedHTTPResponse = try #require(secondCachedResponse as? HTTPURLResponse)
    #expect(secondCachedHTTPResponse.statusCode == 200)
    #expect(secondCachedHTTPResponse.value(forHTTPHeaderField: "Content-Length") == String(cachedPayload.count))
    #expect(secondCachedData == cachedPayload)

    var cachedHeadRequest = URLRequest(url: cachedProxyURL)
    cachedHeadRequest.httpMethod = "HEAD"
    let (cachedHeadData, cachedHeadResponse) = try await proxySession.data(for: cachedHeadRequest)
    let cachedHeadHTTPResponse = try #require(cachedHeadResponse as? HTTPURLResponse)
    #expect(cachedHeadHTTPResponse.statusCode == 200)
    #expect(cachedHeadHTTPResponse.value(forHTTPHeaderField: "Content-Length") == String(cachedPayload.count))
    #expect(cachedHeadData.isEmpty)
    let cachedOriginRequestsAfterOfflineReplay = originRequestCounter.totalRequests(for: cachedSegmentURL)
    #expect(cachedOriginRequestsAfterOfflineReplay == cachedOriginRequestsAfterWarmup)

    let uncachedProxyURL = try facade.proxyURL(for: "MDOFFLINE", kind: .segment, remoteURL: uncachedSegmentURL)
    let (offlineMissData, offlineMissResponse) = try await proxySession.data(from: uncachedProxyURL)
    let offlineMissHTTPResponse = try #require(offlineMissResponse as? HTTPURLResponse)
    #expect(offlineMissHTTPResponse.statusCode == 503)
    #expect(offlineMissHTTPResponse.value(forHTTPHeaderField: "X-HLSCache-Diagnostic-Schema") == "1")
    #expect(offlineMissHTTPResponse.value(forHTTPHeaderField: "X-HLSCache-Error-Code") == "offline_cache_miss")
    #expect(offlineMissHTTPResponse.value(forHTTPHeaderField: "X-HLSCache-Offline-Mode") == "true")
    #expect(offlineMissHTTPResponse.value(forHTTPHeaderField: "X-HLSCache-Missing-Start") == "0")
    #expect(offlineMissHTTPResponse.value(forHTTPHeaderField: "X-HLSCache-Missing-End-Exclusive") == "0")
    #expect(String(data: offlineMissData, encoding: .utf8) == "offline cache miss\n")
    #expect(originRequestCounter.totalRequests(for: uncachedSegmentURL) == 0)

}

private final class ProxyRuntimeOriginURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func setHandler(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func resetHandler() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class RewrittenRouteOriginURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func setHandler(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func resetHandler() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class OfflineModeOriginURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func setHandler(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func resetHandler() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class RotationContinuityOriginURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func setHandler(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func resetHandler() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class CorrelationTraceOriginURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func setHandler(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func resetHandler() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class LegacyFallbackOriginURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func setHandler(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func resetHandler() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private struct StreamingProbeResult {
    let response: HTTPURLResponse
    let data: Data
    let firstBodyByteDelay: TimeInterval
    let totalDuration: TimeInterval
}

private enum StreamingProbeError: Error {
    case invalidRequestURL
    case unsupportedHost(String)
    case socketCreationFailed
    case connectFailed
    case sendFailed
    case receiveFailed
    case invalidHTTPResponse
    case invalidStatusLine
}

private func performStreamingProbeRequest(_ request: URLRequest) throws -> StreamingProbeResult {
    guard let url = request.url else {
        throw StreamingProbeError.invalidRequestURL
    }
    guard let host = url.host else {
        throw StreamingProbeError.invalidRequestURL
    }
    guard host == "127.0.0.1", let port = url.port else {
        throw StreamingProbeError.unsupportedHost(host)
    }

    let method = (request.httpMethod ?? "GET").uppercased()
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    var path = components?.percentEncodedPath ?? url.path
    if path.isEmpty {
        path = "/"
    }
    if let query = components?.percentEncodedQuery, !query.isEmpty {
        path += "?\(query)"
    }

    var requestLines = [
        "\(method) \(path) HTTP/1.1",
        "Host: \(host):\(port)",
        "Connection: close"
    ]
    for key in request.allHTTPHeaderFields?.keys.sorted() ?? [] {
        if let value = request.allHTTPHeaderFields?[key] {
            requestLines.append("\(key): \(value)")
        }
    }
    requestLines.append("")
    requestLines.append("")
    let requestData = Data(requestLines.joined(separator: "\r\n").utf8)

    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFD >= 0 else {
        throw StreamingProbeError.socketCreationFailed
    }
    defer { _ = close(socketFD) }

    var timeout = timeval(tv_sec: 8, tv_usec: 0)
    _ = setsockopt(
        socketFD,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &timeout,
        socklen_t(MemoryLayout<timeval>.size)
    )

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    let ptonResult = host.withCString { cString in
        inet_pton(AF_INET, cString, &address.sin_addr)
    }
    guard ptonResult == 1 else {
        throw StreamingProbeError.unsupportedHost(host)
    }

    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        throw StreamingProbeError.connectFailed
    }

    var bytesSent = 0
    while bytesSent < requestData.count {
        let sent = requestData.withUnsafeBytes { bytes in
            send(socketFD, bytes.baseAddress!.advanced(by: bytesSent), requestData.count - bytesSent, 0)
        }
        guard sent > 0 else {
            throw StreamingProbeError.sendFailed
        }
        bytesSent += sent
    }

    let startedAt = Date()
    let delimiter = Data("\r\n\r\n".utf8)
    var responseBuffer = Data()
    var headerEndOffset: Int?
    var firstBodyByteDelay: TimeInterval?

    var receiveBuffer = [UInt8](repeating: 0, count: 16_384)
    while true {
        let received = receiveBuffer.withUnsafeMutableBytes { bytes in
            recv(socketFD, bytes.baseAddress, bytes.count, 0)
        }

        if received == 0 {
            break
        }
        if received < 0 {
            throw StreamingProbeError.receiveFailed
        }

        responseBuffer.append(receiveBuffer, count: Int(received))
        if headerEndOffset == nil, let delimiterRange = responseBuffer.range(of: delimiter) {
            headerEndOffset = delimiterRange.upperBound
            if responseBuffer.count > delimiterRange.upperBound {
                firstBodyByteDelay = Date().timeIntervalSince(startedAt)
            }
        } else if headerEndOffset != nil, firstBodyByteDelay == nil {
            firstBodyByteDelay = Date().timeIntervalSince(startedAt)
        }
    }

    guard let headerEndOffset else {
        throw StreamingProbeError.invalidHTTPResponse
    }

    guard let headerText = String(data: responseBuffer.prefix(headerEndOffset), encoding: .utf8) else {
        throw StreamingProbeError.invalidHTTPResponse
    }
    let headerLines = headerText
        .components(separatedBy: "\r\n")
        .filter { !$0.isEmpty }
    guard let statusLine = headerLines.first else {
        throw StreamingProbeError.invalidStatusLine
    }

    let statusLineComponents = statusLine.split(separator: " ", omittingEmptySubsequences: true)
    guard statusLineComponents.count >= 2, let statusCode = Int(statusLineComponents[1]) else {
        throw StreamingProbeError.invalidStatusLine
    }

    var headerFields: [String: String] = [:]
    for line in headerLines.dropFirst() {
        guard let separator = line.firstIndex(of: ":") else {
            continue
        }
        let name = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        headerFields[name] = value
    }

    let httpResponse = try #require(
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields
        )
    )
    let body = responseBuffer.suffix(from: headerEndOffset)
    let totalDuration = Date().timeIntervalSince(startedAt)
    return StreamingProbeResult(
        response: httpResponse,
        data: Data(body),
        firstBodyByteDelay: firstBodyByteDelay ?? 0,
        totalDuration: totalDuration
    )
}

private final class StreamingTransportOriginURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func setHandler(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func resetHandler() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class OriginRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(method: String, url: URL)] = []

    func record(method: String, url: URL) {
        lock.lock()
        entries.append((method: method, url: url))
        lock.unlock()
    }

    func totalRequests(for url: URL) -> Int {
        lock.lock()
        let count = entries.filter { $0.url == url }.count
        lock.unlock()
        return count
    }
}
