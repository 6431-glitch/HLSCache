import Foundation

struct CLISettings: Codable, Equatable {
    var defaultUserAgent: String?
}

enum CLISettingsStoreError: Error, Equatable {
    case invalidDefaultUserAgent
}

extension CLISettingsStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidDefaultUserAgent:
            return "Invalid value for default-user-agent. Provide a non-empty string."
        }
    }
}

final class CLISettingsStore {
    private let fileManager: FileManager
    private let fileURL: URL
    private let temporaryFileURL: URL
    private let queue = DispatchQueue(label: "HLSCacheCLI.CLISettingsStore", attributes: .concurrent)
    private var settings = CLISettings()

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL
        self.temporaryFileURL = fileURL.appendingPathExtension("tmp")
        loadFromDisk()
    }

    func current() -> CLISettings {
        queue.sync { settings }
    }

    @discardableResult
    func setDefaultUserAgent(_ value: String) throws -> CLISettings {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw CLISettingsStoreError.invalidDefaultUserAgent
        }

        return try queue.sync(flags: .barrier) {
            settings.defaultUserAgent = normalized
            try saveToDiskAtomic()
            return settings
        }
    }

    private func loadFromDisk() {
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                settings = CLISettings()
                return
            }

            let data = try Data(contentsOf: fileURL)
            settings = try JSONDecoder().decode(CLISettings.self, from: data)
        } catch {
            settings = CLISettings()
        }
    }

    private func saveToDiskAtomic() throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: temporaryFileURL.path) {
            try? fileManager.removeItem(at: temporaryFileURL)
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(settings)
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
