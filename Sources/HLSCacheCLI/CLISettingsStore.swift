import Foundation

struct CLISettings: Codable, Equatable {
    var defaultUserAgent: String?
}

struct CLISettingsLoadDiagnostic: Equatable {
    let result: String
    let settingsPath: String
    let recoveryPath: String
    let recoveryAction: String
    let errorDescription: String
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
    private let corruptFileURL: URL
    private let queue = DispatchQueue(label: "HLSCacheCLI.CLISettingsStore", attributes: .concurrent)
    private var settings = CLISettings()
    private var loadDiagnostics: [CLISettingsLoadDiagnostic] = []

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL
        self.temporaryFileURL = fileURL.appendingPathExtension("tmp")
        self.corruptFileURL = fileURL.appendingPathExtension("corrupt")
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

    func consumeLoadDiagnostics() -> [CLISettingsLoadDiagnostic] {
        queue.sync(flags: .barrier) {
            let snapshot = loadDiagnostics
            loadDiagnostics.removeAll()
            return snapshot
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
        } catch let decodeError as DecodingError {
            recoverFromLoadFailure(loadError: decodeError, result: "recovered_decode_failure")
        } catch {
            recoverFromLoadFailure(loadError: error, result: "recovered_load_failure")
        }
    }

    private func recoverFromLoadFailure(loadError: Error, result: String) {
        settings = CLISettings()
        do {
            if fileManager.fileExists(atPath: corruptFileURL.path) {
                try fileManager.removeItem(at: corruptFileURL)
            }
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.moveItem(at: fileURL, to: corruptFileURL)
            }
            try saveToDiskAtomic()
            let diagnostic = CLISettingsLoadDiagnostic(
                result: result,
                settingsPath: fileURL.path,
                recoveryPath: corruptFileURL.path,
                recoveryAction: "quarantine_and_reset",
                errorDescription: String(describing: loadError)
            )
            queue.sync(flags: .barrier) {
                loadDiagnostics.append(diagnostic)
            }
        } catch {
            let diagnostic = CLISettingsLoadDiagnostic(
                result: "recovery_failed",
                settingsPath: fileURL.path,
                recoveryPath: corruptFileURL.path,
                recoveryAction: "quarantine_and_reset",
                errorDescription: "\(loadError) | recoveryError=\(error)"
            )
            queue.sync(flags: .barrier) {
                loadDiagnostics.append(diagnostic)
            }
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
