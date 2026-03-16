import CoreCache
import Foundation

public enum BackgroundDownloadTaskRegistryError: Error, Equatable, Sendable {
    case invalidTaskIdentifier(Int)
}

public enum BackgroundDownloadRecoveryError: Error, Equatable, Sendable {
    case taskNotFound(Int)
    case invalidFileLength(URL)
}

public struct BackgroundDownloadTaskRecord: Codable, Hashable, Sendable {
    public let taskIdentifier: Int
    public let resourceID: ResourceID
    public let remoteURL: URL
    public let contentType: String?
    public let expectedLength: Int64?
    public let createdAt: Date
    public var lastUpdated: Date

    public init(
        taskIdentifier: Int,
        resourceID: ResourceID,
        remoteURL: URL,
        contentType: String? = nil,
        expectedLength: Int64? = nil,
        createdAt: Date = Date(),
        lastUpdated: Date = Date()
    ) {
        self.taskIdentifier = taskIdentifier
        self.resourceID = resourceID
        self.remoteURL = remoteURL
        self.contentType = contentType
        self.expectedLength = expectedLength
        self.createdAt = createdAt
        self.lastUpdated = lastUpdated
    }
}

public struct BackgroundDownloadRecoveryResult: Equatable, Sendable {
    public let taskIdentifier: Int
    public let resourceID: ResourceID
    public let bytesWritten: Int64
    public let manifest: ResourceRecord

    public init(taskIdentifier: Int, resourceID: ResourceID, bytesWritten: Int64, manifest: ResourceRecord) {
        self.taskIdentifier = taskIdentifier
        self.resourceID = resourceID
        self.bytesWritten = bytesWritten
        self.manifest = manifest
    }
}

public final class BackgroundDownloadTaskRegistry: @unchecked Sendable {
    private static let corruptSnapshotRetentionLimit = 3
    private static let corruptSnapshotFilenamePrefix = "background_download_tasks.json.corrupt."
    private static let corruptSnapshotSequenceLock = NSLock()
    private nonisolated(unsafe) static var corruptSnapshotSequence: UInt64 = 0

    private let fileManager: FileManager
    private let baseDirectory: URL
    private let fileURL: URL
    private let temporaryFileURL: URL
    private let logger: any StructuredLogger
    private let queue = DispatchQueue(label: "HLSCache.BackgroundDownloadTaskRegistry", attributes: .concurrent)

    private var records: [Int: BackgroundDownloadTaskRecord] = [:]

    public init(
        baseDirectory: URL,
        fileName: String = "background_download_tasks.json",
        logger: any StructuredLogger = NoopStructuredLogger()
    ) {
        self.fileManager = .default
        self.baseDirectory = baseDirectory
        self.fileURL = baseDirectory.appendingPathComponent(fileName)
        self.temporaryFileURL = baseDirectory.appendingPathComponent("\(fileName).tmp")
        self.logger = logger
        loadFromDisk()
    }

    @discardableResult
    public func upsert(
        taskIdentifier: Int,
        resourceID: ResourceID,
        remoteURL: URL,
        contentType: String? = nil,
        expectedLength: Int64? = nil,
        clearContentType: Bool = false,
        clearExpectedLength: Bool = false
    ) throws -> BackgroundDownloadTaskRecord {
        guard taskIdentifier > 0 else {
            throw BackgroundDownloadTaskRegistryError.invalidTaskIdentifier(taskIdentifier)
        }

        return try queue.sync(flags: .barrier) {
            let now = Date()
            let existing = records[taskIdentifier]
            let mergedContentType: String?
            if clearContentType {
                mergedContentType = nil
            } else {
                mergedContentType = contentType ?? existing?.contentType
            }
            let mergedExpectedLength: Int64?
            if clearExpectedLength {
                mergedExpectedLength = nil
            } else {
                mergedExpectedLength = expectedLength ?? existing?.expectedLength
            }
            let record = BackgroundDownloadTaskRecord(
                taskIdentifier: taskIdentifier,
                resourceID: resourceID,
                remoteURL: remoteURL,
                contentType: mergedContentType,
                expectedLength: mergedExpectedLength,
                createdAt: existing?.createdAt ?? now,
                lastUpdated: now
            )
            records[taskIdentifier] = record
            try saveToDiskAtomic()
            return record
        }
    }

    public func record(taskIdentifier: Int) -> BackgroundDownloadTaskRecord? {
        queue.sync {
            records[taskIdentifier]
        }
    }

    public func allRecords() -> [BackgroundDownloadTaskRecord] {
        queue.sync {
            records.values.sorted { $0.taskIdentifier < $1.taskIdentifier }
        }
    }

    public func remove(taskIdentifier: Int) throws {
        try queue.sync(flags: .barrier) {
            guard records.removeValue(forKey: taskIdentifier) != nil else {
                return
            }
            try saveToDiskAtomic()
        }
    }

    @discardableResult
    public func retain(taskIdentifiers: Set<Int>) throws -> [BackgroundDownloadTaskRecord] {
        try queue.sync(flags: .barrier) {
            let beforeCount = records.count
            records = records.filter { taskIdentifiers.contains($0.key) }
            if records.count != beforeCount {
                try saveToDiskAtomic()
            }
            return records.values.sorted { $0.taskIdentifier < $1.taskIdentifier }
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
            records = try decoder.decode([Int: BackgroundDownloadTaskRecord].self, from: data)
        } catch let decodeError as DecodingError {
            recoverFromLoadFailure(
                loadError: decodeError,
                result: "recovered_decode_failure"
            )
        } catch {
            recoverFromLoadFailure(
                loadError: error,
                result: "recovered_load_failure"
            )
        }
    }

    private func recoverFromLoadFailure(loadError: Error, result: String) {
        records = [:]
        let snapshotURL = makeCorruptSnapshotURL()

        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.moveItem(at: fileURL, to: snapshotURL)
            }
            let prunedSnapshots = try enforceCorruptSnapshotRetention()
            let retainedSnapshotCount = try existingCorruptSnapshotURLsSortedByAge().count

            try saveToDiskAtomic()
            logger.log(
                StructuredLogEvent(
                    subsystem: "HLSCache",
                    operation: "loadBackgroundDownloadTaskRegistry",
                    level: .warning,
                    metadata: [
                        "result": result,
                        "registryPath": fileURL.path,
                        "recoveryPath": snapshotURL.path,
                        "recoveryAction": "quarantine_and_reset",
                        "retentionLimit": String(Self.corruptSnapshotRetentionLimit),
                        "retentionAction": prunedSnapshots.isEmpty ? "none" : "pruned_old_snapshots",
                        "snapshotCount": String(retainedSnapshotCount),
                        "prunedSnapshotCount": String(prunedSnapshots.count),
                        "prunedSnapshotPaths": prunedSnapshots.map(\.path).joined(separator: ","),
                        "error": String(describing: loadError)
                    ]
                )
            )
        } catch {
            logger.log(
                StructuredLogEvent(
                    subsystem: "HLSCache",
                    operation: "loadBackgroundDownloadTaskRegistry",
                    level: .error,
                    metadata: [
                        "result": "recovery_failed",
                        "registryPath": fileURL.path,
                        "recoveryPath": snapshotURL.path,
                        "error": String(describing: loadError),
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
}

public final class BackgroundDownloadRecoveryCoordinator: @unchecked Sendable {
    private let fileManager: FileManager
    private let baseDirectory: URL
    private let logger: any StructuredLogger
    public let registry: BackgroundDownloadTaskRegistry
    private let diskStore: DiskStore
    private let manifestStore: ManifestStore
    private let queue = DispatchQueue(label: "HLSCache.BackgroundDownloadRecoveryCoordinator", attributes: .concurrent)

    public init(
        baseDirectory: URL,
        registry: BackgroundDownloadTaskRegistry? = nil,
        diskStore: DiskStore? = nil,
        manifestStore: ManifestStore? = nil,
        logger: any StructuredLogger = NoopStructuredLogger()
    ) {
        self.fileManager = .default
        self.baseDirectory = baseDirectory
        self.logger = logger
        self.registry = registry ?? BackgroundDownloadTaskRegistry(baseDirectory: baseDirectory, logger: logger)
        self.diskStore = diskStore ?? DiskStore(baseDirectory: baseDirectory)
        self.manifestStore = manifestStore ?? ManifestStore(baseDirectory: baseDirectory)
        queue.sync(flags: .barrier) {
            reconcileStorageOnStartup()
        }
    }

    @discardableResult
    public func registerTask(
        taskIdentifier: Int,
        resourceID: ResourceID,
        remoteURL: URL,
        contentType: String? = nil,
        expectedLength: Int64? = nil,
        clearContentType: Bool = false,
        clearExpectedLength: Bool = false
    ) throws -> BackgroundDownloadTaskRecord {
        try registry.upsert(
            taskIdentifier: taskIdentifier,
            resourceID: resourceID,
            remoteURL: remoteURL,
            contentType: contentType,
            expectedLength: expectedLength,
            clearContentType: clearContentType,
            clearExpectedLength: clearExpectedLength
        )
    }

    public func taskRecord(for taskIdentifier: Int) -> BackgroundDownloadTaskRecord? {
        registry.record(taskIdentifier: taskIdentifier)
    }

    public func recoverPendingTasks(activeTaskIdentifiers: Set<Int>) throws -> [BackgroundDownloadTaskRecord] {
        try registry.retain(taskIdentifiers: activeTaskIdentifiers)
    }

    @discardableResult
    public func completeDownload(
        taskIdentifier: Int,
        temporaryFileURL: URL,
        contentType: String? = nil,
        expectedLength: Int64? = nil
    ) throws -> BackgroundDownloadRecoveryResult {
        try queue.sync(flags: .barrier) {
            guard let taskRecord = registry.record(taskIdentifier: taskIdentifier) else {
                throw BackgroundDownloadRecoveryError.taskNotFound(taskIdentifier)
            }

            let destinationURL = diskStore.dataFileURL(for: taskRecord.resourceID)
            let stagingURL = destinationURL.appendingPathExtension("downloading")

            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }

            try fileManager.moveItem(at: temporaryFileURL, to: stagingURL)
            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    _ = try fileManager.replaceItemAt(
                        destinationURL,
                        withItemAt: stagingURL,
                        backupItemName: nil,
                        options: [.usingNewMetadataOnly]
                    )
                } else {
                    try fileManager.moveItem(at: stagingURL, to: destinationURL)
                }
            } catch {
                try? fileManager.removeItem(at: stagingURL)
                throw error
            }

            let bytesWritten = try fileLength(at: destinationURL)
            guard bytesWritten >= 0 else {
                throw BackgroundDownloadRecoveryError.invalidFileLength(destinationURL)
            }

            var manifest = try manifestStore.load(resourceID: taskRecord.resourceID)
                ?? ResourceRecord(kind: taskRecord.resourceID.kind)
            if let completeRange = ByteRange(start: 0, endExclusive: bytesWritten) {
                manifest.completedRanges.insert(completeRange)
            }
            manifest.originalURL = taskRecord.remoteURL
            manifest.contentType = contentType ?? taskRecord.contentType ?? manifest.contentType
            manifest.expectedLength = expectedLength ?? taskRecord.expectedLength ?? bytesWritten
            manifest.touch()
            try manifestStore.save(resourceID: taskRecord.resourceID, record: manifest)
            try registry.remove(taskIdentifier: taskIdentifier)

            return BackgroundDownloadRecoveryResult(
                taskIdentifier: taskIdentifier,
                resourceID: taskRecord.resourceID,
                bytesWritten: bytesWritten,
                manifest: manifest
            )
        }
    }

    private func fileLength(at fileURL: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func reconcileStorageOnStartup() {
        let correlationID = UUID().uuidString

        do {
            let manifestIDs = Set(manifestStore.allRecords().map(\.resourceID))
            let dataIDs = Set(allStoredResourceIDs())

            let orphanManifestIDs = manifestIDs.subtracting(dataIDs).sorted(by: Self.resourceIDSort)
            let orphanDataIDs = dataIDs.subtracting(manifestIDs).sorted(by: Self.resourceIDSort)
            let orphanStagingURLs = try allOrphanDownloadStagingURLs()

            var purgedOrphanDataBytes: Int64 = 0
            var purgedOrphanStagingBytes: Int64 = 0

            for resourceID in orphanManifestIDs {
                try manifestStore.delete(resourceID: resourceID)
                logger.log(
                    StructuredLogEvent(
                        subsystem: "HLSCache",
                        operation: "reconcileBackgroundStartup",
                        level: .warning,
                        correlationID: correlationID,
                        metadata: [
                            "action": "purgeOrphanManifest",
                            "cacheKey": resourceID.cacheKey.rawValue,
                            "kind": resourceID.kind.rawValue
                        ]
                    )
                )
            }

            for resourceID in orphanDataIDs {
                let bytes = try diskStore.fileLength(for: resourceID)
                try diskStore.remove(resourceID: resourceID)
                purgedOrphanDataBytes += bytes
                logger.log(
                    StructuredLogEvent(
                        subsystem: "HLSCache",
                        operation: "reconcileBackgroundStartup",
                        level: .warning,
                        correlationID: correlationID,
                        metadata: [
                            "action": "purgeOrphanData",
                            "cacheKey": resourceID.cacheKey.rawValue,
                            "kind": resourceID.kind.rawValue,
                            "bytes": String(bytes)
                        ]
                    )
                )
            }

            for stagingURL in orphanStagingURLs {
                let bytes = (try? fileLength(at: stagingURL)) ?? 0
                try fileManager.removeItem(at: stagingURL)
                purgedOrphanStagingBytes += bytes
                logger.log(
                    StructuredLogEvent(
                        subsystem: "HLSCache",
                        operation: "reconcileBackgroundStartup",
                        level: .warning,
                        correlationID: correlationID,
                        metadata: [
                            "action": "purgeOrphanDownloadStaging",
                            "path": stagingURL.path,
                            "bytes": String(bytes)
                        ]
                    )
                )
            }

            logger.log(
                StructuredLogEvent(
                    subsystem: "HLSCache",
                    operation: "reconcileBackgroundStartup",
                    level: .info,
                    correlationID: correlationID,
                    metadata: [
                        "action": "summary",
                        "orphanManifestCount": String(orphanManifestIDs.count),
                        "orphanDataCount": String(orphanDataIDs.count),
                        "orphanDownloadStagingCount": String(orphanStagingURLs.count),
                        "purgedOrphanDataBytes": String(purgedOrphanDataBytes),
                        "purgedOrphanDownloadStagingBytes": String(purgedOrphanStagingBytes)
                    ]
                )
            )
        } catch {
            logger.log(
                StructuredLogEvent(
                    subsystem: "HLSCache",
                    operation: "reconcileBackgroundStartup",
                    level: .error,
                    correlationID: correlationID,
                    metadata: [
                        "action": "failed",
                        "error": String(describing: error)
                    ]
                )
            )
        }
    }

    private func allOrphanDownloadStagingURLs() throws -> [URL] {
        let cacheDirectory = baseDirectory.appendingPathComponent("cache", isDirectory: true)
        guard fileManager.fileExists(atPath: cacheDirectory.path) else {
            return []
        }

        let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var stagingURLs: [URL] = []
        while let entry = enumerator?.nextObject() as? URL {
            guard entry.pathExtension == "downloading" else {
                continue
            }
            let values = try? entry.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile ?? true else {
                continue
            }
            stagingURLs.append(entry)
        }

        return stagingURLs.sorted { $0.path < $1.path }
    }

    private func allStoredResourceIDs() -> [ResourceID] {
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

        let cacheComponents = cacheDirectory.resolvingSymlinksInPath().pathComponents
        var resourceIDs: [ResourceID] = []
        resourceIDs.reserveCapacity(32)

        for case let fileURL as URL in enumerator {
            guard let resourceID = resourceID(from: fileURL, under: cacheComponents, fileExtension: "bin") else {
                continue
            }
            resourceIDs.append(resourceID)
        }

        return resourceIDs
    }

    private func resourceID(from fileURL: URL, under cacheComponents: [String], fileExtension: String) -> ResourceID? {
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
        return ResourceID(cacheKey: CacheKey(rawValue: components[0]), kind: kind, resourceKey: resourceKey)
    }

    private static func resourceIDSort(lhs: ResourceID, rhs: ResourceID) -> Bool {
        if lhs.cacheKey.rawValue != rhs.cacheKey.rawValue {
            return lhs.cacheKey.rawValue < rhs.cacheKey.rawValue
        }
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.resourceKey < rhs.resourceKey
    }
}
