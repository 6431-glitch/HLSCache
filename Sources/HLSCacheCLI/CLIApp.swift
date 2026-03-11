import Foundation
import HLSCache

struct CLIApp {
    private let context: CLIAppContext
    private let io: any CLIIO
    private let makeExporter: (CLIAppContext) -> CLIExporter
    private let makeDownloader: (CLIAppContext) -> CLIHLSDownloader

    init(
        context: CLIAppContext,
        io: any CLIIO = StandardIO(),
        makeExporter: @escaping (CLIAppContext) -> CLIExporter = { context in
            CLIExporter(baseDirectory: context.baseDirectory, facade: context.facade)
        },
        makeDownloader: @escaping (CLIAppContext) -> CLIHLSDownloader = { context in
            CLIHLSDownloader(baseDirectory: context.baseDirectory, facade: context.facade)
        }
    ) {
        self.context = context
        self.io = io
        self.makeExporter = makeExporter
        self.makeDownloader = makeDownloader
    }

    @discardableResult
    func run(command: CLICommand) -> Int32 {
        switch command {
        case .interactive:
            runInteractive()
            return 0
        case let .register(command):
            return runRegisterCommand(command)
        case .listAliases:
            return runListAliasesCommand()
        case let .download(command):
            return runDownloadCommand(command)
        case let .clearData(command):
            return runClearDataCommand(command, allowPrompt: false)
        case let .exportMP4(command):
            return runExportMP4Command(command)
        case .settingsGet:
            return runSettingsGetCommand()
        case let .settingsSetDefaultUserAgent(value):
            return runSettingsSetDefaultUserAgentCommand(value)
        }
    }

    func runInteractive() {
        io.writeLine("HLSCacheCLI")
        io.writeLine("Base directory: \(context.baseDirectory.path)")
        io.writeLine("Settings path: \(context.settingsFileURL.path)")
        io.writeLine("Proxy base URL: \(context.serverBaseURL.absoluteString)")
        io.writeLine("")

        var shouldExit = false
        while !shouldExit {
            renderMainMenu()

            guard let selection = normalizedInput() else {
                io.writeLine("Input stream closed. Exiting.")
                break
            }

            switch selection.lowercased() {
            case "1":
                runAssetManagementSubflow()
            case "2":
                runProxyServerSubflow()
            case "3":
                runSettingsSubflow()
            case "4":
                runCacheOperationsSubflow()
            case "0", "q", "quit", "exit":
                shouldExit = true
            default:
                io.writeLine("Invalid selection '\(selection)'. Please choose 0-4.")
            }
        }

        io.writeLine("Goodbye.")
    }

    private func renderMainMenu() {
        io.writeLine("Main Menu")
        io.writeLine("1) Asset management")
        io.writeLine("2) Proxy server")
        io.writeLine("3) Settings")
        io.writeLine("4) Cache operations")
        io.writeLine("0) Exit")
        io.writeLine("Choose an option:")
    }

    private func runAssetManagementSubflow() {
        var shouldReturn = false
        while !shouldReturn {
            io.writeLine("")
            io.writeLine("[Asset Management]")
            io.writeLine("1) Add/register asset")
            io.writeLine("2) List aliases")
            io.writeLine("0) Back")
            io.writeLine("Choose an option:")

            guard let selection = normalizedInput() else {
                io.writeLine("Input stream closed. Returning to main menu.")
                return
            }

            switch selection.lowercased() {
            case "0", "b", "back":
                shouldReturn = true
            case "1":
                runInteractiveRegisterAssetFlow()
            case "2":
                runAliasListMonitor()
            default:
                io.writeLine("Invalid selection '\(selection)'. Enter 0 to go back.")
            }
        }
    }

    private func runProxyServerSubflow() {
        var shouldReturn = false
        while !shouldReturn {
            io.writeLine("")
            io.writeLine("[Proxy Server]")
            // Decision path for HLS-90: runtime is ready, so proxy actions stay visible by default.
            let runtimeStatus = context.facade.proxyStatus()
            if let baseURL = runtimeStatus.baseURL {
                io.writeLine("Proxy base URL: \(baseURL.absoluteString)")
            } else {
                io.writeLine("Proxy base URL: (unavailable)")
            }

            io.writeLine("1) Show proxy status")
            io.writeLine("2) Restart proxy server")

            io.writeLine("0) Back")
            io.writeLine("Choose an option:")

            guard let selection = normalizedInput() else {
                io.writeLine("Input stream closed. Returning to main menu.")
                return
            }

            switch selection.lowercased() {
            case "0", "b", "back":
                shouldReturn = true
            case "1":
                runProxyStatusAction()
            case "2":
                runProxyRestartAction()
            default:
                io.writeLine("Invalid selection '\(selection)'. Enter 0 to go back.")
            }
        }
    }

    private func runAliasListMonitor() {
        var shouldReturn = false
        while !shouldReturn {
            io.writeLine("")
            io.writeLine("[Alias List]")
            do {
                for line in try renderAliasListLines(strictCacheInfo: false) {
                    io.writeLine(line)
                }
            } catch {
                io.writeLine("Failed to list aliases: \(error.localizedDescription)")
            }

            io.writeLine("Press Enter to refresh, or q to return.")
            guard let selection = normalizedInput() else {
                io.writeLine("Input stream closed. Returning to Asset Management menu.")
                shouldReturn = true
                continue
            }

            if selection.lowercased() == "q" {
                shouldReturn = true
            }
        }
    }

    private func formattedListDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }

    private func runListAliasesCommand() -> Int32 {
        do {
            for line in try renderAliasListLines(strictCacheInfo: true) {
                io.writeLine(line)
            }
            return 0
        } catch {
            io.writeErrorLine("Failed to list aliases: \(error.localizedDescription)")
            return 1
        }
    }

    private func renderAliasListLines(strictCacheInfo: Bool) throws -> [String] {
        let aliases = context.facade.listAliases()
        guard !aliases.isEmpty else {
            return ["(no aliases registered)"]
        }

        var lines: [String] = []
        lines.reserveCapacity(aliases.count * 2)

        for record in aliases {
            let cacheBytes: Int64
            if strictCacheInfo {
                cacheBytes = try context.facade.cacheInfo(alias: record.alias).totalBytesOnDisk
            } else {
                cacheBytes = (try? context.facade.cacheInfo(alias: record.alias).totalBytesOnDisk) ?? 0
            }

            let updated = formattedListDate(record.lastUpdated)
            lines.append("- \(record.alias) | assetID=\(record.assetID) | bytes=\(cacheBytes) | updated=\(updated)")
            lines.append("  remote=\(record.currentRemoteURL.absoluteString)")
        }

        return lines
    }

    private func runSettingsSubflow() {
        var shouldReturn = false
        while !shouldReturn {
            io.writeLine("")
            io.writeLine("[Settings]")
            io.writeLine("1) Show settings")
            io.writeLine("2) Set default User-Agent")
            io.writeLine("0) Back")
            io.writeLine("Choose an option:")

            guard let selection = normalizedInput() else {
                io.writeLine("Input stream closed. Returning to main menu.")
                return
            }

            switch selection.lowercased() {
            case "0", "b", "back":
                shouldReturn = true
            case "1":
                _ = runSettingsGetCommand()
            case "2":
                io.writeLine("Default User-Agent value:")
                guard let value = normalizedInput() else {
                    io.writeLine("Input stream closed. Returning to settings menu.")
                    continue
                }
                _ = runSettingsSetDefaultUserAgentCommand(value)
            default:
                io.writeLine("Invalid selection '\(selection)'. Enter 0 to go back.")
            }
        }
    }

    private func runCacheOperationsSubflow() {
        var shouldReturn = false
        while !shouldReturn {
            io.writeLine("")
            io.writeLine("[Cache Operations]")
            io.writeLine("1) Clear cache by alias")
            io.writeLine("2) Clear all cache")
            io.writeLine("0) Back")
            io.writeLine("Choose an option:")

            guard let selection = normalizedInput() else {
                io.writeLine("Input stream closed. Returning to main menu.")
                return
            }

            switch selection.lowercased() {
            case "0", "b", "back":
                shouldReturn = true
            case "1":
                runInteractiveClearDataFlow(scope: .alias(""))
            case "2":
                runInteractiveClearDataFlow(scope: .all)
            default:
                io.writeLine("Invalid selection '\(selection)'. Enter 0 to go back.")
            }
        }
    }

    private func runProxyStatusAction() {
        let status = context.facade.proxyStatus()
        let aliasCount = context.facade.listAliases().count
        io.writeLine("Proxy status:")
        writeProxyStatusContext(status)
        if !status.isRunning {
            io.writeLine("Proxy server is not running.")
        }
        io.writeLine("Registered aliases: \(aliasCount)")
    }

    @discardableResult
    private func runProxyRestartAction() -> Int32 {
        let before = context.facade.proxyStatus()
        io.writeLine("Restarting proxy server...")
        io.writeLine("Before restart:")
        writeProxyStatusContext(before)

        context.facade.stopServer()

        let restartHost = before.host ?? context.serverBaseURL.host ?? CLIArguments.defaultHost
        let restartPort = before.port ?? context.serverBaseURL.port ?? CLIArguments.defaultPort
        let restarted = context.facade.startServer(
            host: restartHost,
            port: restartPort
        )
        let after = context.facade.proxyStatus()

        guard after.isRunning else {
            io.writeLine("Failed to restart proxy server.")
            io.writeLine("Attempted host: \(restartHost)")
            io.writeLine("Attempted port: \(restartPort)")
            io.writeLine("Current base URL: \(after.baseURL?.absoluteString ?? "(unavailable)")")
            io.writeLine("Action: verify runtime configuration and try again.")
            return 1
        }

        io.writeLine("Proxy server restarted.")
        io.writeLine("After restart:")
        writeProxyStatusContext(after)
        io.writeLine("Resolved base URL: \(restarted.absoluteString)")
        return 0
    }

    private func writeProxyStatusContext(_ status: ProxyServerStatus) {
        io.writeLine("State: \(status.isRunning ? "running" : "stopped")")
        io.writeLine("Host: \(status.host ?? "(unavailable)")")
        io.writeLine("Port: \(status.port.map(String.init) ?? "(unavailable)")")
        io.writeLine("Base URL: \(status.baseURL?.absoluteString ?? "(unavailable)")")
    }

    private func runInteractiveRegisterAssetFlow() {
        io.writeLine("")
        io.writeLine("Add/Register Asset")
        io.writeLine("Alias (required):")
        guard let alias = requireNonEmptyInput(fieldName: "Alias") else {
            return
        }

        io.writeLine("Asset ID (required):")
        guard let assetID = requireNonEmptyInput(fieldName: "Asset ID") else {
            return
        }

        io.writeLine("Remote URL (required):")
        guard let remoteURLRaw = requireNonEmptyInput(fieldName: "Remote URL") else {
            return
        }

        let remoteURL: URL
        do {
            remoteURL = try CLIArguments.parseRemoteURL(remoteURLRaw)
        } catch {
            io.writeLine(error.localizedDescription)
            return
        }

        io.writeLine("Optional headers in 'Name: Value' format. Submit empty line to finish.")
        var headers: [String: String] = [:]
        while true {
            guard let raw = normalizedInput() else {
                io.writeLine("Input stream closed. Continuing without more headers.")
                break
            }

            if raw.isEmpty {
                break
            }

            do {
                let (key, value) = try CLIArguments.parseHeader(raw)
                headers[key] = value
            } catch {
                io.writeLine(error.localizedDescription)
            }
        }

        let command = RegisterAssetCommand(
            alias: alias,
            assetID: assetID,
            remoteURL: remoteURL,
            headers: headers.isEmpty ? nil : headers
        )
        _ = runRegisterCommand(command)
    }

    private func runRegisterCommand(_ command: RegisterAssetCommand) -> Int32 {
        do {
            let effectiveHeaders = mergedHeadersWithDefaultUserAgent(command.headers)
            let record = try context.facade.register(
                alias: command.alias,
                assetID: command.assetID,
                remoteURL: command.remoteURL,
                headers: effectiveHeaders
            )

            io.writeLine("Asset registered successfully.")
            io.writeLine("Alias: \(record.alias)")
            io.writeLine("Cache Key: \(record.cacheKey.rawValue)")
            io.writeLine("Remote URL: \(record.currentRemoteURL.absoluteString)")

            if let headers = record.headers, !headers.isEmpty {
                io.writeLine("Headers:")
                for key in headers.keys.sorted() {
                    io.writeLine("  \(key): \(headers[key] ?? "")")
                }
            } else {
                io.writeLine("Headers: (none)")
            }

            return 0
        } catch {
            io.writeLine("Failed to register asset: \(error.localizedDescription)")
            return 1
        }
    }

    private func runInteractiveClearDataFlow(scope: ClearDataScope) {
        let resolvedScope: ClearDataScope
        switch scope {
        case .alias:
            io.writeLine("Alias to clear (required):")
            guard let alias = requireNonEmptyInput(fieldName: "Alias") else {
                return
            }
            resolvedScope = .alias(alias)
        case .all:
            resolvedScope = .all
        }

        io.writeLine("Delete alias metadata too? (y/N):")
        let shouldDeleteAliasMetadata = readYesNoInput(defaultValue: false)
        let command = ClearDataCommand(
            scope: resolvedScope,
            removeAliasMetadata: shouldDeleteAliasMetadata,
            bypassConfirmation: false
        )
        _ = runClearDataCommand(command, allowPrompt: true)
    }

    private func runClearDataCommand(_ command: ClearDataCommand, allowPrompt: Bool) -> Int32 {
        guard command.bypassConfirmation || allowPrompt else {
            io.writeLine("Refusing destructive clear command without confirmation. Re-run with --yes.")
            return 1
        }

        if !command.bypassConfirmation {
            io.writeLine("This operation is destructive.")
            io.writeLine("Type '--yes' to confirm, or anything else to cancel:")
            guard let confirmation = normalizedInput() else {
                io.writeLine("Input stream closed. Clear operation cancelled.")
                return 1
            }
            guard confirmation == "--yes" || confirmation.caseInsensitiveCompare("yes") == .orderedSame else {
                io.writeLine("Clear operation cancelled.")
                return 1
            }
        }

        do {
            switch command.scope {
            case let .alias(alias):
                return try runClearByAlias(alias: alias, removeAliasMetadata: command.removeAliasMetadata)
            case .all:
                return try runClearAll(removeAliasMetadata: command.removeAliasMetadata)
            }
        } catch let error as HLSCacheError {
            switch error {
            case let .aliasNotFound(alias):
                io.writeLine("Alias '\(alias)' was not found.")
                return 1
            case .serverNotRunning:
                io.writeLine("Proxy server is not running.")
                return 1
            }
        } catch {
            io.writeLine("Failed to clear data: \(error.localizedDescription)")
            return 1
        }
    }

    private func runClearByAlias(alias: String, removeAliasMetadata: Bool) throws -> Int32 {
        try context.facade.clearCache(alias: alias)
        io.writeLine("Cleared cache for alias '\(alias)'.")

        if removeAliasMetadata {
            _ = try context.facade.removeAlias(alias: alias)
            io.writeLine("Alias metadata removed for '\(alias)'.")
        }

        let stillPresent = context.facade.listAliases().contains { $0.alias == alias }
        io.writeLine("Post-clear verification:")
        io.writeLine("Alias state: \(stillPresent ? "present" : "removed")")

        if stillPresent {
            let info = try context.facade.cacheInfo(alias: alias)
            io.writeLine("Cache bytes: \(info.totalBytesOnDisk)")
        }

        return 0
    }

    private func runClearAll(removeAliasMetadata: Bool) throws -> Int32 {
        let aliasesBefore = context.facade.listAliases()
        try context.facade.clearCache()
        io.writeLine("Cleared cache for all aliases.")

        if removeAliasMetadata {
            let removedCount = try context.facade.removeAllAliases()
            io.writeLine("Removed alias metadata for \(removedCount) aliases.")
        }

        let aliasesAfter = context.facade.listAliases()
        io.writeLine("Post-clear verification:")
        io.writeLine("Alias count: \(aliasesAfter.count)")

        if !removeAliasMetadata {
            var totalBytes: Int64 = 0
            for record in aliasesBefore {
                if aliasesAfter.contains(where: { $0.alias == record.alias }) {
                    totalBytes += try context.facade.cacheInfo(alias: record.alias).totalBytesOnDisk
                }
            }
            io.writeLine("Total cache bytes across aliases: \(totalBytes)")
        }

        return 0
    }

    private func runExportMP4Command(_ command: ExportMP4Command) -> Int32 {
        do {
            let exporter = makeExporter(context)
            let result = try exporter.export(alias: command.alias, outputURL: command.outputURL)
            io.writeLine("Export completed successfully.")
            io.writeLine("Alias: \(command.alias)")
            io.writeLine("Output: \(result.outputURL.path)")
            io.writeLine("Output size: \(result.outputBytes) bytes")
            return 0
        } catch {
            io.writeLine(error.localizedDescription)
            return 1
        }
    }

    private func runDownloadCommand(_ command: DownloadCommand) -> Int32 {
        do {
            let downloader = makeDownloader(context)
            let result = try downloader.download(alias: command.alias)
            io.writeLine("Download completed successfully.")
            io.writeLine("Alias: \(result.alias)")
            io.writeLine("Playlists cached: \(result.playlistCount)")
            io.writeLine("Media playlists: \(result.mediaPlaylistCount)")
            io.writeLine("Segments cached: \(result.segmentCount)")
            io.writeLine("Keys cached: \(result.keyCount)")
            io.writeLine("Bytes written: \(result.bytesWritten)")
            return 0
        } catch {
            io.writeLine(error.localizedDescription)
            return 1
        }
    }

    private func mergedHeadersWithDefaultUserAgent(_ providedHeaders: [String: String]?) -> [String: String]? {
        var headers = providedHeaders ?? [:]
        let settings = context.settingsStore.current()

        if let defaultUserAgent = settings.defaultUserAgent,
           !defaultUserAgent.isEmpty,
           !headers.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            headers["User-Agent"] = defaultUserAgent
        }

        return headers.isEmpty ? nil : headers
    }

    private func runSettingsGetCommand() -> Int32 {
        let settings = context.settingsStore.current()
        io.writeLine("Settings file: \(context.settingsFileURL.path)")
        if let userAgent = settings.defaultUserAgent, !userAgent.isEmpty {
            io.writeLine("defaultUserAgent: \(userAgent)")
        } else {
            io.writeLine("defaultUserAgent: (unset)")
        }
        return 0
    }

    private func runSettingsSetDefaultUserAgentCommand(_ value: String) -> Int32 {
        do {
            let settings = try context.settingsStore.setDefaultUserAgent(value)
            io.writeLine("Settings updated.")
            io.writeLine("Settings file: \(context.settingsFileURL.path)")
            io.writeLine("defaultUserAgent: \(settings.defaultUserAgent ?? "")")
            return 0
        } catch {
            io.writeLine(error.localizedDescription)
            return 1
        }
    }

    private func requireNonEmptyInput(fieldName: String) -> String? {
        guard let value = normalizedInput() else {
            io.writeLine("Input stream closed. Returning to menu.")
            return nil
        }
        guard !value.isEmpty else {
            io.writeLine("\(fieldName) is required.")
            return nil
        }
        return value
    }

    private func readYesNoInput(defaultValue: Bool) -> Bool {
        guard let value = normalizedInput(), !value.isEmpty else {
            return defaultValue
        }
        switch value.lowercased() {
        case "y", "yes":
            return true
        case "n", "no":
            return false
        default:
            return defaultValue
        }
    }

    private func normalizedInput() -> String? {
        io.readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
