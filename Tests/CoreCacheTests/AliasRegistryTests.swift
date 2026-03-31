import Foundation
import Logging
import Testing
@testable import CoreCache

private func makeTempDirectory(prefix: String = "alias-registry-tests") throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(prefix)
        .appendingPathComponent(UUID().uuidString)

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func aliasRegistryCorruptSnapshots(in directory: URL) throws -> [URL] {
    let entries = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )
    return entries
        .filter { $0.lastPathComponent.hasPrefix("alias_registry.json.corrupt.") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
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

    init(label: String = "tests.aliasRegistry", minimumLevel: Logger.Level = .trace) {
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

@Test func aliasRegistry_registerAndResolve_returnsExpectedRecord() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let registry = AliasRegistry(baseDirectory: directory)
    let remoteURL = try #require(URL(string: "https://cdn.example.com/media/master.m3u8"))
    let headers = ["Authorization": "Bearer abc"]

    let registered = try registry.register(
        alias: "MD0534",
        assetID: "movie-0534",
        remoteURL: remoteURL,
        headers: headers
    )

    let resolved = try #require(registry.resolve(alias: "MD0534"))
    #expect(resolved == registered)
    #expect(resolved.assetID == "movie-0534")
    #expect(resolved.cacheKey == CacheKey.fromAssetID("movie-0534"))
    #expect(resolved.currentRemoteURL == remoteURL)
    #expect(resolved.headers == headers)
}

@Test func aliasRegistry_persistsAcrossInstances() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = AliasRegistry(baseDirectory: directory)
    let remoteURL = try #require(URL(string: "https://origin.example.com/asset.m3u8"))

    let record = try first.register(
        alias: "MD1000",
        assetID: "asset-1000",
        remoteURL: remoteURL,
        headers: ["User-Agent": "HLSCache"]
    )

    let second = AliasRegistry(baseDirectory: directory)
    let restored = try #require(second.resolve(alias: "MD1000"))

    #expect(restored.alias == record.alias)
    #expect(restored.assetID == record.assetID)
    #expect(restored.cacheKey == record.cacheKey)
    #expect(restored.currentRemoteURL == record.currentRemoteURL)
    #expect(restored.headers == record.headers)
    #expect(abs(restored.lastUpdated.timeIntervalSince(record.lastUpdated)) < 1.0)
    #expect(restored.cacheKey == CacheKey.fromAssetID("asset-1000"))
}

@Test func aliasRegistry_updateRemoteURL_keepsCacheKeyAndUpdatesTimestamp() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let registry = AliasRegistry(baseDirectory: directory)

    let oldURL = try #require(URL(string: "https://a.example.com/media.m3u8"))
    let initial = try registry.register(
        alias: "MD2000",
        assetID: "asset-2000",
        remoteURL: oldURL,
        headers: nil
    )

    let newURL = try #require(URL(string: "https://b.example.com/media.m3u8"))
    let updated = try registry.updateRemoteURL(alias: "MD2000", remoteURL: newURL)

    #expect(updated.cacheKey == initial.cacheKey)
    #expect(updated.currentRemoteURL == newURL)
    #expect(updated.lastUpdated >= initial.lastUpdated)
}

@Test func aliasRegistry_updateRemoteURL_missingAlias_throwsAliasNotFound() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let registry = AliasRegistry(baseDirectory: directory)
    let newURL = try #require(URL(string: "https://missing.example.com/media.m3u8"))

    do {
        _ = try registry.updateRemoteURL(alias: "UNKNOWN", remoteURL: newURL)
        #expect(Bool(false))
    } catch let error as AliasRegistryError {
        #expect(error == .aliasNotFound("UNKNOWN"))
    } catch {
        #expect(Bool(false))
    }
}

@Test func aliasRegistry_atomicWrite_producesExistingValidJSONFile() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let registry = AliasRegistry(baseDirectory: directory)
    let remoteURL = try #require(URL(string: "https://cdn.example.com/x.m3u8"))

    _ = try registry.register(alias: "MD3000", assetID: "asset-3000", remoteURL: remoteURL, headers: nil)

    let fileURL = directory.appendingPathComponent("alias_registry.json")
    #expect(FileManager.default.fileExists(atPath: fileURL.path))

    let data = try Data(contentsOf: fileURL)
    _ = try JSONSerialization.jsonObject(with: data)

    let decoded = try JSONDecoder.withISO8601.decode([Alias: AssetRecord].self, from: data)
    #expect(decoded["MD3000"]?.cacheKey == CacheKey.fromAssetID("asset-3000"))
}

@Test func aliasRegistry_atomicWrite_doesNotLeaveTemporaryFile() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let registry = AliasRegistry(baseDirectory: directory)
    let firstURL = try #require(URL(string: "https://cdn.example.com/first.m3u8"))
    let secondURL = try #require(URL(string: "https://cdn.example.com/second.m3u8"))

    _ = try registry.register(alias: "MD3500", assetID: "asset-3500", remoteURL: firstURL, headers: nil)
    _ = try registry.updateRemoteURL(alias: "MD3500", remoteURL: secondURL)

    let tmpFileURL = directory.appendingPathComponent("alias_registry.json.tmp")
    #expect(!FileManager.default.fileExists(atPath: tmpFileURL.path))
}

@Test func aliasRegistry_concurrencySmoke_readWhileUpdating_noCorruption() async throws {
    let directory = try makeTempDirectory(prefix: "alias-registry-concurrency")
    defer { try? FileManager.default.removeItem(at: directory) }

    let registry = AliasRegistry(baseDirectory: directory)
    _ = try registry.register(
        alias: "MD4000",
        assetID: "asset-4000",
        remoteURL: try #require(URL(string: "https://cdn.example.com/v0.m3u8")),
        headers: ["X-Test": "1"]
    )

    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
            group.addTask {
                for _ in 0..<500 {
                    _ = registry.resolve(alias: "MD4000")
                }
            }
        }

        group.addTask {
            for index in 1...200 {
                let url = try #require(URL(string: "https://cdn.example.com/v\(index).m3u8"))
                _ = try registry.updateRemoteURL(alias: "MD4000", remoteURL: url)
            }
        }

        try await group.waitForAll()
    }

    let finalRecord = try #require(registry.resolve(alias: "MD4000"))
    #expect(finalRecord.cacheKey == CacheKey.fromAssetID("asset-4000"))
    #expect(finalRecord.currentRemoteURL.absoluteString.hasPrefix("https://cdn.example.com/v"))

    let fileURL = directory.appendingPathComponent("alias_registry.json")
    let data = try Data(contentsOf: fileURL)
    _ = try JSONSerialization.jsonObject(with: data)

    let reloaded = AliasRegistry(baseDirectory: directory)
    let restored = try #require(reloaded.resolve(alias: "MD4000"))
    #expect(restored.cacheKey == CacheKey.fromAssetID("asset-4000"))
}

@Test func aliasRegistry_unregister_removesSingleAliasAndPersists() throws {
    let directory = try makeTempDirectory(prefix: "alias-registry-unregister")
    defer { try? FileManager.default.removeItem(at: directory) }

    let registry = AliasRegistry(baseDirectory: directory)
    let remoteURL = try #require(URL(string: "https://cdn.example.com/unregister.m3u8"))
    _ = try registry.register(alias: "MDDEL1", assetID: "asset-del-1", remoteURL: remoteURL, headers: nil)
    _ = try registry.register(alias: "MDDEL2", assetID: "asset-del-2", remoteURL: remoteURL, headers: nil)

    let removed = try registry.unregister(alias: "MDDEL1")
    #expect(removed.alias == "MDDEL1")
    #expect(registry.resolve(alias: "MDDEL1") == nil)
    #expect(registry.resolve(alias: "MDDEL2") != nil)

    let reloaded = AliasRegistry(baseDirectory: directory)
    #expect(reloaded.resolve(alias: "MDDEL1") == nil)
    #expect(reloaded.resolve(alias: "MDDEL2") != nil)
}

@Test func aliasRegistry_unregisterAll_clearsAllAliasesAndPersists() throws {
    let directory = try makeTempDirectory(prefix: "alias-registry-unregister-all")
    defer { try? FileManager.default.removeItem(at: directory) }

    let registry = AliasRegistry(baseDirectory: directory)
    let remoteURL = try #require(URL(string: "https://cdn.example.com/unregister-all.m3u8"))
    _ = try registry.register(alias: "MDALL1", assetID: "asset-all-1", remoteURL: remoteURL, headers: nil)
    _ = try registry.register(alias: "MDALL2", assetID: "asset-all-2", remoteURL: remoteURL, headers: nil)

    let removedCount = try registry.unregisterAll()
    #expect(removedCount == 2)
    #expect(registry.allRecords().isEmpty)

    let reloaded = AliasRegistry(baseDirectory: directory)
    #expect(reloaded.allRecords().isEmpty)
}

@Test func aliasRegistry_decodeFailure_quarantinesCorruptFileAndEmitsTelemetry() throws {
    let directory = try makeTempDirectory(prefix: "alias-registry-decode-failure")
    defer { try? FileManager.default.removeItem(at: directory) }

    let registryFileURL = directory.appendingPathComponent("alias_registry.json")
    let corruptData = Data("{invalid-json".utf8)
    try corruptData.write(to: registryFileURL)

    let logger = RecordingStructuredLogger()
    let registry = AliasRegistry(baseDirectory: directory, logger: logger.logger)

    #expect(registry.allRecords().isEmpty)

    let snapshots = try aliasRegistryCorruptSnapshots(in: directory)
    #expect(snapshots.count == 1)
    let snapshotURL = try #require(snapshots.first)
    #expect(FileManager.default.fileExists(atPath: registryFileURL.path))
    #expect(try Data(contentsOf: snapshotURL) == corruptData)

    let restoredData = try Data(contentsOf: registryFileURL)
    let restoredRecords = try JSONDecoder.withISO8601.decode([Alias: AssetRecord].self, from: restoredData)
    #expect(restoredRecords.isEmpty)

    let event = try #require(
        logger.events().first {
            $0.operation == "loadAliasRegistry"

        }
    )
    #expect(event.level == .warning)
}

@Test func aliasRegistry_decodeFailure_retainsTimestampedSnapshots_withBoundedRetention() throws {
    let directory = try makeTempDirectory(prefix: "alias-registry-decode-failure-retention")
    defer { try? FileManager.default.removeItem(at: directory) }

    let logger = RecordingStructuredLogger()
    let registryFileURL = directory.appendingPathComponent("alias_registry.json")

    for index in 0..<5 {
        let corruptData = Data("{invalid-\(index)".utf8)
        try corruptData.write(to: registryFileURL)
        _ = AliasRegistry(baseDirectory: directory, logger: logger.logger)
    }

    let snapshots = try aliasRegistryCorruptSnapshots(in: directory)
    #expect(snapshots.count == 3)

    let retainedPayloads = try snapshots.map { snapshotURL in
        String(decoding: try Data(contentsOf: snapshotURL), as: UTF8.self)
    }
    #expect(!retainedPayloads.contains("{invalid-0"))
    #expect(!retainedPayloads.contains("{invalid-1"))
    #expect(retainedPayloads.contains("{invalid-4"))

    _ = try #require(
        logger.events().first {
            $0.operation == "loadAliasRegistry"


        }
    )
}

@Test func aliasRegistry_decodeFailure_recoveryStillAllowsFutureWrites() throws {
    let directory = try makeTempDirectory(prefix: "alias-registry-decode-failure-writes")
    defer { try? FileManager.default.removeItem(at: directory) }

    let registryFileURL = directory.appendingPathComponent("alias_registry.json")
    try Data("not-json".utf8).write(to: registryFileURL)

    let registry = AliasRegistry(baseDirectory: directory)
    let remoteURL = try #require(URL(string: "https://cdn.example.com/recovered.m3u8"))
    _ = try registry.register(alias: "MDRECOVER", assetID: "asset-recovered", remoteURL: remoteURL, headers: nil)

    let restored = try #require(registry.resolve(alias: "MDRECOVER"))
    #expect(restored.cacheKey == CacheKey.fromAssetID("asset-recovered"))
}

private extension JSONDecoder {
    static var withISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
