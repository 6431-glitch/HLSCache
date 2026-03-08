import Foundation

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
            return try decoder.decode(ResourceRecord.self, from: data)
        }
    }

    public func save(resourceID: ResourceID, record: ResourceRecord) throws {
        try queue.sync(flags: .barrier) {
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
}
