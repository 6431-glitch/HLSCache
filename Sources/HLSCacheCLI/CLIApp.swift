import Foundation

struct CLIApp {
    private let context: CLIAppContext
    private let io: any CLIIO

    init(context: CLIAppContext, io: any CLIIO = StandardIO()) {
        self.context = context
        self.io = io
    }

    @discardableResult
    func run(command: CLICommand) -> Int32 {
        switch command {
        case .interactive:
            runInteractive()
            return 0
        case let .register(command):
            return runRegisterCommand(command)
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
                runSubflow(
                    title: "Proxy Server",
                    options: [
                        "1) Show proxy status (coming soon)",
                        "2) Restart proxy server (coming soon)"
                    ]
                )
            case "3":
                runSettingsSubflow()
            case "4":
                runSubflow(
                    title: "Cache Operations",
                    options: [
                        "1) Show cache summary (coming soon)",
                        "2) Clear cache by alias (coming soon)"
                    ]
                )
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
            io.writeLine("2) List aliases (coming soon)")
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
                io.writeLine("Option 2 in Asset Management is not implemented yet.")
            default:
                io.writeLine("Invalid selection '\(selection)'. Enter 0 to go back.")
            }
        }
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

    private func runSubflow(title: String, options: [String]) {
        var shouldReturn = false
        while !shouldReturn {
            io.writeLine("")
            io.writeLine("[\(title)]")
            for option in options {
                io.writeLine(option)
            }
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
                if title == "Settings" {
                    io.writeLine("Settings file: \(context.settingsFileURL.path)")
                } else {
                    io.writeLine("Option 1 in \(title) is not implemented yet.")
                }
            case "2":
                io.writeLine("Option 2 in \(title) is not implemented yet.")
            default:
                io.writeLine("Invalid selection '\(selection)'. Enter 0 to go back.")
            }
        }
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

    private func normalizedInput() -> String? {
        io.readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
