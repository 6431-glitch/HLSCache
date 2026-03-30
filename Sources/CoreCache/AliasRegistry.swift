import Foundation
import Logging

public enum AliasRegistryError: Error, Equatable, Sendable {
    case aliasNotFound(Alias)
}

public struct AssetRecord: Codable, Hashable, Sendable {
    public let alias: Alias
    public let assetID: AssetID
    public let cacheKey: CacheKey
    public var currentRemoteURL: URL
    public var headers: [String: String]?
    public var lastUpdated: Date

    public init(
        alias: Alias,
        assetID: AssetID,
        currentRemoteURL: URL,
        headers: [String: String]? = nil,
        lastUpdated: Date = Date()
    ) {
        self.alias = alias
        self.assetID = assetID
        self.cacheKey = CacheKey.fromAssetID(assetID)
        self.currentRemoteURL = currentRemoteURL
        self.headers = headers
        self.lastUpdated = lastUpdated
    }

    enum CodingKeys: String, CodingKey {
        case alias
        case assetID
        case cacheKey
        case currentRemoteURL
        case headers
        case lastUpdated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let alias = try container.decode(Alias.self, forKey: .alias)
        let assetID = try container.decode(AssetID.self, forKey: .assetID)
        let currentRemoteURL = try container.decode(URL.self, forKey: .currentRemoteURL)
        let headers = try container.decodeIfPresent([String: String].self, forKey: .headers)
        let lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)

        // Decode stored value for schema compatibility, but enforce derived identity.
        _ = try container.decodeIfPresent(CacheKey.self, forKey: .cacheKey)

        self.alias = alias
        self.assetID = assetID
        self.cacheKey = CacheKey.fromAssetID(assetID)
        self.currentRemoteURL = currentRemoteURL
        self.headers = headers
        self.lastUpdated = lastUpdated
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(alias, forKey: .alias)
        try container.encode(assetID, forKey: .assetID)
        try container.encode(cacheKey, forKey: .cacheKey)
        try container.encode(currentRemoteURL, forKey: .currentRemoteURL)
        try container.encodeIfPresent(headers, forKey: .headers)
        try container.encode(lastUpdated, forKey: .lastUpdated)
    }
}

public final class AliasRegistry: @unchecked Sendable, Loggable {
    private static let corruptSnapshotRetentionLimit = 3
    private static let corruptSnapshotFilenamePrefix = "alias_registry.json.corrupt."
    private static let corruptSnapshotSequenceLock = NSLock()
    private nonisolated(unsafe) static var corruptSnapshotSequence: UInt64 = 0

    private let fileManager: FileManager
    private let baseDirectory: URL
    private let fileURL: URL
    private let temporaryFileURL: URL
    private let configuredLogger: Logger
    private let queue = DispatchQueue(label: "CoreCache.AliasRegistry", attributes: .concurrent)

    private var records: [Alias: AssetRecord] = [:]

    public init(
        baseDirectory: URL,
        logger: Logger = Logger(label: String(reflecting: AliasRegistry.self))
    ) {
        self.fileManager = .default
        self.baseDirectory = baseDirectory
        self.fileURL = baseDirectory.appendingPathComponent("alias_registry.json")
        self.temporaryFileURL = baseDirectory.appendingPathComponent("alias_registry.json.tmp")
        self.configuredLogger = logger
        loadFromDisk()
    }

    /// Registers or overwrites a record for `alias` using the provided asset identity and network metadata.
    public func register(
        alias: Alias,
        assetID: AssetID,
        remoteURL: URL,
        headers: [String: String]?
    ) throws -> AssetRecord {
        try queue.sync(flags: .barrier) {
            let record = AssetRecord(
                alias: alias,
                assetID: assetID,
                currentRemoteURL: remoteURL,
                headers: headers,
                lastUpdated: Date()
            )

            records[alias] = record
            try saveToDiskAtomic()
            return record
        }
    }

    /// Rotates only the remote URL metadata for an existing alias without changing asset identity.
    public func updateRemoteURL(alias: Alias, remoteURL: URL) throws -> AssetRecord {
        try queue.sync(flags: .barrier) {
            guard var existing = records[alias] else {
                throw AliasRegistryError.aliasNotFound(alias)
            }

            existing.currentRemoteURL = remoteURL
            existing.lastUpdated = Date()
            records[alias] = existing

            try saveToDiskAtomic()
            return existing
        }
    }

    public func resolve(alias: Alias) -> AssetRecord? {
        queue.sync {
            records[alias]
        }
    }

    public func allRecords() -> [AssetRecord] {
        queue.sync {
            records.values.sorted { $0.alias < $1.alias }
        }
    }

    /// Removes a single alias record from the registry.
    @discardableResult
    public func unregister(alias: Alias) throws -> AssetRecord {
        try queue.sync(flags: .barrier) {
            guard let removed = records.removeValue(forKey: alias) else {
                throw AliasRegistryError.aliasNotFound(alias)
            }
            try saveToDiskAtomic()
            return removed
        }
    }

    /// Removes every alias record from the registry.
    @discardableResult
    public func unregisterAll() throws -> Int {
        try queue.sync(flags: .barrier) {
            let count = records.count
            records.removeAll(keepingCapacity: false)
            try saveToDiskAtomic()
            return count
        }
    }

    private func loadFromDisk() {
        do {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

            guard fileManager.fileExists(atPath: fileURL.path) else {
                records = [:]
                return
            }

            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let decoded = try decoder.decode([Alias: AssetRecord].self, from: data)
            records = Dictionary(uniqueKeysWithValues: decoded.map { alias, record in
                (
                    alias,
                    AssetRecord(
                        alias: alias,
                        assetID: record.assetID,
                        currentRemoteURL: record.currentRemoteURL,
                        headers: record.headers,
                        lastUpdated: record.lastUpdated
                    )
                )
            })
        } catch let decodeError as DecodingError {
            recoverFromDecodeFailure(decodeError)
        } catch {
            records = [:]
            activeLogger.log(
                StructuredLogEvent(
                    subsystem: "CoreCache",
                    operation: "loadAliasRegistry",
                    level: .error,
                    metadata: [
                        "result": "load_failed",
                        "registryPath": fileURL.path,
                        "error": String(describing: error)
                    ]
                )
            )
        }
    }

    private func recoverFromDecodeFailure(_ decodeError: DecodingError) {
        records = [:]

        do {
            let snapshotURL = makeCorruptSnapshotURL()
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.moveItem(at: fileURL, to: snapshotURL)
            }
            let prunedSnapshots = try enforceCorruptSnapshotRetention()

            try saveToDiskAtomic()
            activeLogger.log(
                StructuredLogEvent(
                    subsystem: "CoreCache",
                    operation: "loadAliasRegistry",
                    level: .warning,
                    metadata: [
                        "result": "recovered_decode_failure",
                        "registryPath": fileURL.path,
                        "recoveryPath": snapshotURL.path,
                        "recoveryAction": "quarantine_and_reset",
                        "retentionLimit": String(Self.corruptSnapshotRetentionLimit),
                        "retentionAction": prunedSnapshots.isEmpty ? "none" : "pruned_old_snapshots",
                        "prunedSnapshotCount": String(prunedSnapshots.count),
                        "prunedSnapshotPaths": prunedSnapshots.map(\.path).joined(separator: ","),
                        "error": String(describing: decodeError)
                    ]
                )
            )
        } catch {
            activeLogger.log(
                StructuredLogEvent(
                    subsystem: "CoreCache",
                    operation: "loadAliasRegistry",
                    level: .error,
                    metadata: [
                        "result": "recovery_failed",
                        "registryPath": fileURL.path,
                        "recoveryPath": "",
                        "error": String(describing: decodeError),
                        "recoveryError": String(describing: error)
                    ]
                )
            )
        }
    }

    private func makeCorruptSnapshotURL() -> URL {
        let timestampMilliseconds = Int64(Date().timeIntervalSince1970 * 1000)
        let sequence = Self.nextCorruptSnapshotSequence()
        let filename = String(
            format: "\(Self.corruptSnapshotFilenamePrefix)%013lld-%020llu",
            timestampMilliseconds,
            sequence
        )
        return baseDirectory.appendingPathComponent(filename)
    }

    private func enforceCorruptSnapshotRetention() throws -> [URL] {
        let snapshots = try existingCorruptSnapshotURLsSortedByAge()
        let overflowCount = snapshots.count - Self.corruptSnapshotRetentionLimit
        guard overflowCount > 0 else {
            return []
        }

        var prunedSnapshots: [URL] = []
        for snapshotURL in snapshots.prefix(overflowCount) {
            if fileManager.fileExists(atPath: snapshotURL.path) {
                try fileManager.removeItem(at: snapshotURL)
                prunedSnapshots.append(snapshotURL)
            }
        }

        return prunedSnapshots
    }

    private func existingCorruptSnapshotURLsSortedByAge() throws -> [URL] {
        let entries = try fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        return entries
            .filter { $0.lastPathComponent.hasPrefix(Self.corruptSnapshotFilenamePrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func nextCorruptSnapshotSequence() -> UInt64 {
        corruptSnapshotSequenceLock.lock()
        defer { corruptSnapshotSequenceLock.unlock() }
        corruptSnapshotSequence += 1
        return corruptSnapshotSequence
    }

    private func saveToDiskAtomic() throws {
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)

        if fileManager.fileExists(atPath: temporaryFileURL.path) {
            try? fileManager.removeItem(at: temporaryFileURL)
        }

        do {
            try data.write(to: temporaryFileURL)

            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(
                    fileURL,
                    withItemAt: temporaryFileURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(at: temporaryFileURL, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryFileURL)
            throw error
        }
    }

    private var activeLogger: Logger {
        configuredLogger
    }
}
