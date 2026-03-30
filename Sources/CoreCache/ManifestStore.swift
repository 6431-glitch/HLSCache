import Foundation
import Logging

public struct StoredManifestRecord: Sendable {
    public let resourceID: ResourceID
    public let record: ResourceRecord

    public init(resourceID: ResourceID, record: ResourceRecord) {
        self.resourceID = resourceID
        self.record = record
    }
}

struct ManifestResourceIDScanResult: Sendable {
    let resourceIDs: [ResourceID]
    let recoveredCorruptedManifestCount: Int
    let purgedCorruptedManifestDataBytes: Int64
}

public final class ManifestStore: @unchecked Sendable, Loggable {
    private let fileManager: FileManager
    private let baseDirectory: URL
    private let configuredLogger: Logger
    private let queue = DispatchQueue(label: "CoreCache.ManifestStore", attributes: .concurrent)

    public init(
        baseDirectory: URL,
        logger: Logger = Logger(label: String(reflecting: ManifestStore.self))
    ) {
        self.fileManager = .default
        self.baseDirectory = baseDirectory
        self.configuredLogger = logger
    }

    public func manifestFileURL(for resourceID: ResourceID) -> URL {
        baseDirectory
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent(resourceID.cacheKey.rawValue, isDirectory: true)
            .appendingPathComponent("resources", isDirectory: true)
            .appendingPathComponent(resourceID.kind.rawValue, isDirectory: true)
            .appendingPathComponent("\(resourceID.resourceKey).json")
    }

    public func load(resourceID: ResourceID) throws -> ResourceRecord? {
        try queue.sync(flags: .barrier) {
            let fileURL = manifestFileURL(for: resourceID)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                return nil
            }

            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                return try decoder.decode(ResourceRecord.self, from: data)
            } catch {
                quarantineCorruptedManifest(
                    fileURL: fileURL,
                    resourceID: resourceID,
                    decodeError: error,
                    source: "load"
                )
                // Corrupted manifests are quarantined and treated as cache misses so cache can self-heal.
                return nil
            }
        }
    }

    public func save(resourceID: ResourceID, record: ResourceRecord) throws {
        try queue.sync(flags: .barrier) {
            try record.validateInvariants()
            let fileURL = manifestFileURL(for: resourceID)
            let temporaryURL = fileURL.appendingPathExtension("tmp")

            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(record)

            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }

            do {
                try data.write(to: temporaryURL)

                if fileManager.fileExists(atPath: fileURL.path) {
                    _ = try fileManager.replaceItemAt(
                        fileURL,
                        withItemAt: temporaryURL,
                        backupItemName: nil,
                        options: [.usingNewMetadataOnly]
                    )
                } else {
                    try fileManager.moveItem(at: temporaryURL, to: fileURL)
                }
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                throw error
            }
        }
    }

    public func delete(resourceID: ResourceID) throws {
        try queue.sync(flags: .barrier) {
            let fileURL = manifestFileURL(for: resourceID)
            let temporaryURL = fileURL.appendingPathExtension("tmp")

            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }
    }

    public func allRecords() -> [StoredManifestRecord] {
        queue.sync(flags: .barrier) {
            let cacheDirectory = baseDirectory.appendingPathComponent("cache", isDirectory: true)
            guard fileManager.fileExists(atPath: cacheDirectory.path) else {
                return []
            }

            guard let enumerator = fileManager.enumerator(
                at: cacheDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }

            var records: [StoredManifestRecord] = []
            let cacheComponents = cacheDirectory.resolvingSymlinksInPath().pathComponents

            for case let fileURL as URL in enumerator {
                guard let resourceID = resourceID(
                    from: fileURL,
                    under: cacheComponents,
                    fileExtension: "json"
                ) else {
                    continue
                }

                guard let data = try? Data(contentsOf: fileURL) else {
                    continue
                }

                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601

                let record: ResourceRecord
                do {
                    record = try decoder.decode(ResourceRecord.self, from: data)
                } catch {
                    quarantineCorruptedManifest(
                        fileURL: fileURL,
                        resourceID: resourceID,
                        decodeError: error,
                        source: "allRecords"
                    )
                    continue
                }

                records.append(StoredManifestRecord(resourceID: resourceID, record: record))
            }

            return records
        }
    }

    func allManifestResourceIDs() -> [ResourceID] {
        scanManifestResourceIDs().resourceIDs
    }

    func scanManifestResourceIDs() -> ManifestResourceIDScanResult {
        queue.sync(flags: .barrier) {
            let cacheDirectory = baseDirectory.appendingPathComponent("cache", isDirectory: true)
            guard fileManager.fileExists(atPath: cacheDirectory.path) else {
                return ManifestResourceIDScanResult(
                    resourceIDs: [],
                    recoveredCorruptedManifestCount: 0,
                    purgedCorruptedManifestDataBytes: 0
                )
            }

            guard let enumerator = fileManager.enumerator(
                at: cacheDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return ManifestResourceIDScanResult(
                    resourceIDs: [],
                    recoveredCorruptedManifestCount: 0,
                    purgedCorruptedManifestDataBytes: 0
                )
            }

            let cacheComponents = cacheDirectory.resolvingSymlinksInPath().pathComponents
            var resourceIDs: [ResourceID] = []
            resourceIDs.reserveCapacity(32)
            var recoveredCorruptedManifestCount = 0
            var purgedCorruptedManifestDataBytes: Int64 = 0

            for case let fileURL as URL in enumerator {
                guard let resourceID = resourceID(
                    from: fileURL,
                    under: cacheComponents,
                    fileExtension: "json"
                ) else {
                    continue
                }

                guard let data = try? Data(contentsOf: fileURL) else {
                    continue
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                do {
                    _ = try decoder.decode(ResourceRecord.self, from: data)
                } catch {
                    if let purgedDataBytes = quarantineCorruptedManifest(
                        fileURL: fileURL,
                        resourceID: resourceID,
                        decodeError: error,
                        source: "allManifestResourceIDs"
                    ) {
                        recoveredCorruptedManifestCount += 1
                        purgedCorruptedManifestDataBytes += purgedDataBytes
                    }
                    continue
                }
                resourceIDs.append(resourceID)
            }

            return ManifestResourceIDScanResult(
                resourceIDs: resourceIDs,
                recoveredCorruptedManifestCount: recoveredCorruptedManifestCount,
                purgedCorruptedManifestDataBytes: purgedCorruptedManifestDataBytes
            )
        }
    }

    @discardableResult
    private func quarantineCorruptedManifest(
        fileURL: URL,
        resourceID: ResourceID,
        decodeError: Error,
        source: String
    ) -> Int64? {
        let quarantineURL = fileURL.appendingPathExtension("corrupt")
        let dataFileURL = dataFileURL(for: resourceID)
        let correlationID = UUID().uuidString

        do {
            if fileManager.fileExists(atPath: quarantineURL.path) {
                try fileManager.removeItem(at: quarantineURL)
            }

            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.moveItem(at: fileURL, to: quarantineURL)
            }

            let temporaryURL = fileURL.appendingPathExtension("tmp")
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }

            var purgedDataBytes: Int64 = 0
            if fileManager.fileExists(atPath: dataFileURL.path) {
                purgedDataBytes = (try? fileSize(at: dataFileURL)) ?? 0
                try fileManager.removeItem(at: dataFileURL)
            }

            activeLogger.log(
                StructuredLogEvent(
                    subsystem: "CoreCache",
                    operation: "manifestDecodeRecovery",
                    level: .warning,
                    correlationID: correlationID,
                    metadata: [
                        "result": "recovered_decode_failure",
                        "source": source,
                        "cacheKey": resourceID.cacheKey.rawValue,
                        "kind": resourceID.kind.rawValue,
                        "resourceKey": resourceID.resourceKey,
                        "manifestPath": fileURL.path,
                        "quarantinePath": quarantineURL.path,
                        "recoveryAction": "quarantine_manifest_and_purge_data",
                        "purgedDataBytes": String(purgedDataBytes),
                        "error": String(describing: decodeError)
                    ]
                )
            )
            return purgedDataBytes
        } catch {
            activeLogger.log(
                StructuredLogEvent(
                    subsystem: "CoreCache",
                    operation: "manifestDecodeRecovery",
                    level: .error,
                    correlationID: correlationID,
                    metadata: [
                        "result": "recovery_failed",
                        "source": source,
                        "cacheKey": resourceID.cacheKey.rawValue,
                        "kind": resourceID.kind.rawValue,
                        "resourceKey": resourceID.resourceKey,
                        "manifestPath": fileURL.path,
                        "quarantinePath": quarantineURL.path,
                        "recoveryAction": "quarantine_manifest_and_purge_data",
                        "error": String(describing: decodeError),
                        "recoveryError": String(describing: error)
                    ]
                )
            )
            return nil
        }
    }

    private func dataFileURL(for resourceID: ResourceID) -> URL {
        manifestFileURL(for: resourceID).deletingPathExtension().appendingPathExtension("bin")
    }

    private func fileSize(at fileURL: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func resourceID(
        from fileURL: URL,
        under cacheComponents: [String],
        fileExtension: String
    ) -> ResourceID? {
        guard fileURL.pathExtension == fileExtension else {
            return nil
        }

        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            return nil
        }

        let fileComponents = fileURL.resolvingSymlinksInPath().pathComponents
        guard fileComponents.count >= cacheComponents.count,
              Array(fileComponents.prefix(cacheComponents.count)) == cacheComponents else {
            return nil
        }

        let components = Array(fileComponents.dropFirst(cacheComponents.count))
        guard components.count == 4,
              components[1] == "resources",
              let kind = ResourceKind(rawValue: components[2]) else {
            return nil
        }

        let resourceKey = URL(fileURLWithPath: components[3]).deletingPathExtension().lastPathComponent
        return ResourceID(
            cacheKey: CacheKey(rawValue: components[0]),
            kind: kind,
            resourceKey: resourceKey
        )
    }

    private var activeLogger: Logger {
        configuredLogger
    }
}
