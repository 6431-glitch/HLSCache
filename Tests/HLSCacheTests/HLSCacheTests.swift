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

    let operations = Set(logger.events().map(\.operation))
    #expect(operations.contains("startServer"))
    #expect(operations.contains("register"))
    #expect(operations.contains("proxyURL"))
    #expect(operations.contains("cacheInfo"))
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
