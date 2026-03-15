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
    private let fileManager: FileManager
    private let baseDirectory: URL
    private let fileURL: URL
    private let temporaryFileURL: URL
    private let corruptFileURL: URL
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
        self.corruptFileURL = baseDirectory.appendingPathComponent("\(fileName).corrupt")
        self.logger = logger
        loadFromDisk()
    }

    @discardableResult
    public func upsert(
        taskIdentifier: Int,
        resourceID: ResourceID,
        remoteURL: URL,
        contentType: String? = nil,
        expectedLength: Int64? = nil
    ) throws -> BackgroundDownloadTaskRecord {
        guard taskIdentifier > 0 else {
            throw BackgroundDownloadTaskRegistryError.invalidTaskIdentifier(taskIdentifier)
        }

        return try queue.sync(flags: .barrier) {
            let now = Date()
            let existing = records[taskIdentifier]
            let record = BackgroundDownloadTaskRecord(
                taskIdentifier: taskIdentifier,
                resourceID: resourceID,
                remoteURL: remoteURL,
                contentType: contentType,
                expectedLength: expectedLength,
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
            recoverFromDecodeFailure(decodeError)
        } catch {
            records = [:]
            logger.log(
                StructuredLogEvent(
                    subsystem: "HLSCache",
                    operation: "loadBackgroundDownloadTaskRegistry",
                    level: .error,
                    metadata: [
                        "result": "load_failed",
                        "registryPath": fileURL.path,
                        "recoveryAction": "in_memory_reset",
                        "error": String(describing: error)
                    ]
                )
            )
        }
    }

    private func recoverFromDecodeFailure(_ decodeError: DecodingError) {
        records = [:]

        do {
            if fileManager.fileExists(atPath: corruptFileURL.path) {
                try fileManager.removeItem(at: corruptFileURL)
            }

            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.moveItem(at: fileURL, to: corruptFileURL)
            }

            try saveToDiskAtomic()
            logger.log(
                StructuredLogEvent(
                    subsystem: "HLSCache",
                    operation: "loadBackgroundDownloadTaskRegistry",
                    level: .warning,
                    metadata: [
                        "result": "recovered_decode_failure",
                        "registryPath": fileURL.path,
                        "recoveryPath": corruptFileURL.path,
                        "recoveryAction": "quarantine_and_reset",
                        "error": String(describing: decodeError)
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
                        "recoveryPath": corruptFileURL.path,
                        "error": String(describing: decodeError),
                        "recoveryError": String(describing: error)
                    ]
                )
            )
        }
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
        self.registry = registry ?? BackgroundDownloadTaskRegistry(baseDirectory: baseDirectory, logger: logger)
        self.diskStore = diskStore ?? DiskStore(baseDirectory: baseDirectory)
        self.manifestStore = manifestStore ?? ManifestStore(baseDirectory: baseDirectory)
    }

    @discardableResult
    public func registerTask(
        taskIdentifier: Int,
        resourceID: ResourceID,
        remoteURL: URL,
        contentType: String? = nil,
        expectedLength: Int64? = nil
    ) throws -> BackgroundDownloadTaskRecord {
        try registry.upsert(
            taskIdentifier: taskIdentifier,
            resourceID: resourceID,
            remoteURL: remoteURL,
            contentType: contentType,
            expectedLength: expectedLength
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
}
