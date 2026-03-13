import Foundation
import HLSCache

struct CLIAppContext {
    let baseDirectory: URL
    let settingsFileURL: URL
    let settingsStore: CLISettingsStore
    let facade: HLSCacheFacade
    let serverBaseURL: URL

    init(arguments: CLIArguments, fileManager: FileManager = .default) throws {
        let resolvedBaseDirectory = arguments.baseDirectory ?? defaultBaseDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: resolvedBaseDirectory, withIntermediateDirectories: true)

        let settingsFileURL = resolvedBaseDirectory.appendingPathComponent("cli_settings.json")
        let settingsStore = CLISettingsStore(fileURL: settingsFileURL, fileManager: fileManager)
        let facade = HLSCacheFacade(baseDirectory: resolvedBaseDirectory)
        let serverBaseURL: URL
        do {
            serverBaseURL = try facade.startServer(host: arguments.host, port: arguments.port)
        } catch let error as ProxyServerRuntimeError {
            switch error {
            case .listenerBindFailed where arguments.port == CLIArguments.defaultPort:
                // Keep CLI startup resilient under parallel test/process contention on the default port.
                serverBaseURL = try facade.startServer(host: arguments.host, port: 0)
            case .listenerStartupTimedOut where arguments.port == CLIArguments.defaultPort:
                // Keep CLI startup resilient under parallel test/process contention on the default port.
                serverBaseURL = try facade.startServer(host: arguments.host, port: 0)
            default:
                throw error
            }
        }

        self.baseDirectory = resolvedBaseDirectory
        self.settingsFileURL = settingsFileURL
        self.settingsStore = settingsStore
        self.facade = facade
        self.serverBaseURL = serverBaseURL
    }
}

private func defaultBaseDirectory(fileManager: FileManager) -> URL {
    let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? fileManager.temporaryDirectory
    return applicationSupport.appendingPathComponent("HLSCacheCLI", isDirectory: true)
}
