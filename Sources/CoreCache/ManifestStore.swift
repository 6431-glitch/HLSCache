import Foundation

public struct StoredManifestRecord: Sendable {
    public let resourceID: ResourceID
    public let record: ResourceRecord

    public init(resourceID: ResourceID, record: ResourceRecord) {
        self.resourceID = resourceID
        self.record = record
    }
}

public final class ManifestStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let baseDirectory: URL
    private let queue = DispatchQueue(label: "CoreCache.ManifestStore", attributes: .concurrent)

    public init(baseDirectory: URL) {
        self.fileManager = .default
        self.baseDirectory = baseDirectory
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
        try queue.sync {
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
                // Treat partially-written or corrupted manifests as cache misses so cache can self-heal.
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
        queue.sync {
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

                guard let record = try? decoder.decode(ResourceRecord.self, from: data) else {
                    continue
                }

                records.append(StoredManifestRecord(resourceID: resourceID, record: record))
            }

            return records
        }
    }

    func allManifestResourceIDs() -> [ResourceID] {
        queue.sync {
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
                guard let resourceID = resourceID(
                    from: fileURL,
                    under: cacheComponents,
                    fileExtension: "json"
                ) else {
                    continue
                }
                resourceIDs.append(resourceID)
            }

            return resourceIDs
        }
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
}
