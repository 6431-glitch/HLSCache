import CoreCache
import Foundation
import Testing
@testable import HLSCache

private struct TestPlugin: HLSCachePlugin {
    let id: String
    let version: String
}

private final class RecordingStructuredLogger: StructuredLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [StructuredLogEvent] = []

    func log(_ event: StructuredLogEvent) {
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

    let baseURL = facade.startServer(port: 18080)
    #expect(baseURL.absoluteString == "http://127.0.0.1:18080")

    let proxy = try facade.proxyURL(for: "MD0534")
    #expect(proxy.absoluteString == "http://127.0.0.1:18080/MD0534")

    let updated = try facade.updateRemoteURL(
        alias: "MD0534",
        remoteURL: try #require(URL(string: "https://cdn2.example.com/master.m3u8"))
    )
    #expect(updated.currentRemoteURL.absoluteString == "https://cdn2.example.com/master.m3u8")
}

@Test func facade_proxyStatus_reportsDeterministicLifecycleState() throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-proxy-status")
    defer { try? FileManager.default.removeItem(at: directory) }

    let facade = HLSCacheFacade(baseDirectory: directory)

    let initial = facade.proxyStatus()
    #expect(initial.isRunning == false)
    #expect(initial.host == nil)
    #expect(initial.port == nil)
    #expect(initial.baseURL == nil)

    _ = facade.startServer(host: "0.0.0.0", port: 18888)
    let started = facade.proxyStatus()
    #expect(started.isRunning == true)
    #expect(started.host == "0.0.0.0")
    #expect(started.port == 18888)
    #expect(started.baseURL?.absoluteString == "http://0.0.0.0:18888")

    _ = facade.startServer(host: "127.0.0.1", port: 19999)
    let restartedWithoutStop = facade.proxyStatus()
    #expect(restartedWithoutStop == started)

    facade.stopServer()
    let stopped = facade.proxyStatus()
    #expect(stopped.isRunning == false)
    #expect(stopped.host == nil)
    #expect(stopped.port == nil)
    #expect(stopped.baseURL == nil)

    _ = facade.startServer(port: 0)
    let defaultPort = facade.proxyStatus()
    #expect(defaultPort.isRunning == true)
    #expect(defaultPort.host == "127.0.0.1")
    #expect(defaultPort.port == 8080)
    #expect(defaultPort.baseURL?.absoluteString == "http://127.0.0.1:8080")
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

    _ = facade.startServer(port: 18484)
    let proxyBefore = try facade.proxyURL(for: "MDROT")

    let coreCache = CoreCache(baseDirectory: directory)
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

@Test func facade_proxyRouting_buildAndDecode_roundTripsEncodedRemoteURL() throws {
    let directory = try makeHLSCacheTempDirectory(prefix: "hlscache-proxy-routing")
    defer { try? FileManager.default.removeItem(at: directory) }

    let facade = HLSCacheFacade(baseDirectory: directory)
    _ = try facade.register(
        alias: "MD0534",
        assetID: "asset-0534",
        remoteURL: try #require(URL(string: "https://cdn.example.com/master.m3u8"))
    )
    _ = facade.startServer(port: 18181)

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
    _ = facade.startServer(port: 18282)

    let requestURL = try #require(URL(string: "http://127.0.0.1:18282/MISSING/seg/https%3A%2F%2Fcdn.example.com%2Fv.ts"))

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

    let logger = RecordingStructuredLogger()
    let facade = HLSCacheFacade(baseDirectory: directory, logger: logger)

    _ = facade.startServer(port: 18383)
    _ = try facade.register(
        alias: "MDLOG",
        assetID: "asset-log",
        remoteURL: try #require(URL(string: "https://cdn.example.com/log.m3u8"))
    )
    _ = try facade.proxyURL(for: "MDLOG")
    _ = try facade.cacheInfo(alias: "MDLOG")

    let events = logger.events()
    #expect(events.allSatisfy { !$0.correlationID.isEmpty })

    let startServerEvent = try #require(events.first { $0.operation == "startServer" })
    let registerEvent = try #require(events.first { $0.operation == "register" })
    let proxyURLEvent = try #require(events.first { $0.operation == "proxyURL" })
    let cacheInfoEvent = try #require(events.first { $0.operation == "cacheInfo" })

    #expect(startServerEvent.level == .info)
    #expect(registerEvent.level == .info)
    #expect(proxyURLEvent.level == .debug)
    #expect(cacheInfoEvent.level == .debug)
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
    let coreCache = CoreCache(baseDirectory: directory)
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
    _ = facade.startServer(port: 19090)

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
