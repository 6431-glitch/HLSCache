import Foundation

enum CLIArgumentParseError: Error, Equatable {
    case missingValue(String)
    case missingRequiredArgument(String)
    case invalidPort(String)
    case invalidURL(String)
    case invalidHeader(String)
    case invalidOutputFormat(String)
    case invalidSettingValue(String)
    case invalidArgument(String)
    case unknownOption(String)
    case unknownCommand(String)
}

extension CLIArgumentParseError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .missingValue(option):
            return "Missing value for option '\(option)'."
        case let .missingRequiredArgument(argument):
            return "Missing required argument '\(argument)'."
        case let .invalidPort(value):
            return "Invalid port '\(value)'. Port must be an integer between 1 and 65535."
        case let .invalidURL(value):
            return "Invalid URL '\(value)'. Please provide an absolute URL like https://example.com/video.m3u8."
        case let .invalidHeader(value):
            return "Invalid header '\(value)'. Use the format 'Header-Name: Header-Value'."
        case let .invalidOutputFormat(value):
            return "Invalid output format '\(value)'. Use 'text' or 'json'."
        case let .invalidSettingValue(name):
            return "Invalid value for setting '\(name)'."
        case let .invalidArgument(value):
            return "Invalid argument '\(value)'."
        case let .unknownOption(option):
            return "Unknown option '\(option)'."
        case let .unknownCommand(command):
            return "Unknown command '\(command)'."
        }
    }
}

enum CLICommand: Equatable {
    case interactive
    case register(RegisterAssetCommand)
    case listAliases
    case download(DownloadCommand)
    case proxy(ProxyCommand)
    case clearData(ClearDataCommand)
    case exportMP4(ExportMP4Command)
    case settingsGet
    case settingsSetDefaultUserAgent(String)
}

struct RegisterAssetCommand: Equatable {
    let alias: String
    let assetID: String
    let remoteURL: URL
    let headers: [String: String]?
}

struct DownloadCommand: Equatable {
    let alias: String
}

enum ProxyCommandAction: Equatable {
    case status
    case restart
}

struct ProxyCommand: Equatable {
    let action: ProxyCommandAction
}

enum ClearDataScope: Equatable {
    case alias(String)
    case all
}

struct ClearDataCommand: Equatable {
    let scope: ClearDataScope
    let removeAliasMetadata: Bool
    let bypassConfirmation: Bool
}

enum ExportVideoCodec: Equatable {
    case copy
    case av1(AV1TranscodeOptions)
}

struct AV1TranscodeOptions: Equatable {
    static let defaultPreset = "6"
    static let defaultCRF = 32

    let preset: String
    let crf: Int
    let bitrate: String?
}

struct ExportMP4Command: Equatable {
    let alias: String
    let outputURL: URL
    let videoCodec: ExportVideoCodec

    init(alias: String, outputURL: URL, videoCodec: ExportVideoCodec = .copy) {
        self.alias = alias
        self.outputURL = outputURL
        self.videoCodec = videoCodec
    }
}

struct CLIArguments: Equatable {
    static let defaultHost = "127.0.0.1"
    static let defaultPort = 8080

    let baseDirectory: URL?
    let host: String
    let port: Int
    let outputFormat: CLIOutputFormat
    let showHelp: Bool
    let command: CLICommand

    init(
        baseDirectory: URL? = nil,
        host: String = CLIArguments.defaultHost,
        port: Int = CLIArguments.defaultPort,
        outputFormat: CLIOutputFormat = .text,
        showHelp: Bool = false,
        command: CLICommand = .interactive
    ) {
        self.baseDirectory = baseDirectory
        self.host = host
        self.port = port
        self.outputFormat = outputFormat
        self.showHelp = showHelp
        self.command = command
    }

    static func parse(_ args: [String]) throws -> CLIArguments {
        var baseDirectory: URL?
        var host = defaultHost
        var port = defaultPort
        var outputFormat: CLIOutputFormat = .text
        var showHelp = false
        var command: CLICommand = .interactive

        var index = 0
        while index < args.count {
            let option = args[index]
            switch option {
            case "--help", "-h":
                showHelp = true
                index += 1
            case "--base-directory":
                index += 1
                guard index < args.count else {
                    throw CLIArgumentParseError.missingValue(option)
                }
                baseDirectory = URL(fileURLWithPath: args[index]).standardizedFileURL
                index += 1
            case "--host":
                index += 1
                guard index < args.count else {
                    throw CLIArgumentParseError.missingValue(option)
                }
                host = args[index]
                index += 1
            case "--port":
                index += 1
                guard index < args.count else {
                    throw CLIArgumentParseError.missingValue(option)
                }

                let value = args[index]
                guard let parsed = Int(value), (1...65535).contains(parsed) else {
                    throw CLIArgumentParseError.invalidPort(value)
                }
                port = parsed
                index += 1
            case "--output-format":
                index += 1
                guard index < args.count else {
                    throw CLIArgumentParseError.missingValue(option)
                }

                let value = args[index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard let parsed = CLIOutputFormat(rawValue: value) else {
                    throw CLIArgumentParseError.invalidOutputFormat(args[index])
                }
                outputFormat = parsed
                index += 1
            case "add", "register":
                let commandArgs = Array(args[(index + 1)...])
                command = try parseRegisterCommand(commandArgs)
                index = args.count
            case "download":
                let commandArgs = Array(args[(index + 1)...])
                command = try parseDownloadCommand(commandArgs)
                index = args.count
            case "proxy":
                let commandArgs = Array(args[(index + 1)...])
                command = try parseProxyCommand(commandArgs)
                index = args.count
            case "list":
                let commandArgs = Array(args[(index + 1)...])
                command = try parseListCommand(commandArgs)
                index = args.count
            case "clear":
                let commandArgs = Array(args[(index + 1)...])
                command = try parseClearDataCommand(commandArgs)
                index = args.count
            case "export":
                let commandArgs = Array(args[(index + 1)...])
                command = try parseExportCommand(commandArgs)
                index = args.count
            case "settings":
                let commandArgs = Array(args[(index + 1)...])
                command = try parseSettingsCommand(commandArgs)
                index = args.count
            default:
                if option.hasPrefix("-") {
                    throw CLIArgumentParseError.unknownOption(option)
                }
                throw CLIArgumentParseError.unknownCommand(option)
            }
        }

        return CLIArguments(
            baseDirectory: baseDirectory,
            host: host,
            port: port,
            outputFormat: outputFormat,
            showHelp: showHelp,
            command: command
        )
    }

    static var usage: String {
        """
        Usage:
          swift run HLSCacheCLI [options]
          swift run HLSCacheCLI [options] add --alias <alias> --asset-id <asset-id> --url <remote-url> [--header "Name: Value"]
          swift run HLSCacheCLI [options] register --alias <alias> --asset-id <asset-id> --url <remote-url> [--header "Name: Value"]
          swift run HLSCacheCLI [options] list
          swift run HLSCacheCLI [options] download --alias <alias>
          swift run HLSCacheCLI [options] proxy status
          swift run HLSCacheCLI [options] proxy restart
          swift run HLSCacheCLI [options] clear --alias <alias> [--delete-alias] --yes
          swift run HLSCacheCLI [options] clear --all [--delete-alias] --yes
          swift run HLSCacheCLI [options] export --alias <alias> --output <file.mp4> [--av1] [--av1-preset <preset>] [--av1-crf <0...63>] [--av1-bitrate <value>]
          swift run HLSCacheCLI [options] settings get
          swift run HLSCacheCLI [options] settings set default-user-agent "<value>"

        Options:
          --base-directory <path>   Base directory for cache and settings storage.
          --host <host>             Proxy host (default: \(defaultHost)).
          --port <port>             Proxy port (default: \(defaultPort)).
          --output-format <format>  Output format: text (default) or json.
          --help, -h                Show this help message.

        Commands:
          add, register             Add or update an alias mapping.
                                   Required: --alias, --asset-id, --url
                                   Optional: repeat --header "Name: Value"
          list                      Print registered aliases and cache metadata.
          download                  Cache entire HLS content for an alias.
                                   Required: --alias
          proxy status              Print non-interactive proxy runtime status.
          proxy restart             Restart proxy runtime non-interactively.
          clear                     Clear cache bytes by alias or all aliases.
                                   Required: one of --alias <alias> or --all
                                   Optional: --delete-alias to remove alias metadata
                                   Required for non-interactive use: --yes
          export                    Export cached HLS media to MP4.
                                   Required: --alias, --output <file.mp4>
                                   Optional: --av1 for AV1 transcode mode
                                   Optional AV1 tuning: --av1-preset, --av1-crf, --av1-bitrate
                                   AV1 bitrate format: <positive-int><k|M> (for example 1200k, 2M)
          settings get              Show persisted CLI settings.
          settings set default-user-agent "<value>"
                                   Persist global default User-Agent.
        """
    }

    private static func parseDownloadCommand(_ args: [String]) throws -> CLICommand {
        var alias: String?
        var index = 0

        while index < args.count {
            let option = args[index]
            switch option {
            case "--alias":
                index += 1
                guard index < args.count else {
                    throw CLIArgumentParseError.missingValue(option)
                }
                alias = args[index]
                index += 1
            default:
                if option.hasPrefix("-") {
                    throw CLIArgumentParseError.unknownOption(option)
                }
                throw CLIArgumentParseError.unknownCommand(option)
            }
        }

        guard let alias, !alias.isEmpty else {
            throw CLIArgumentParseError.missingRequiredArgument("--alias")
        }

        return .download(DownloadCommand(alias: alias))
    }

    private static func parseProxyCommand(_ args: [String]) throws -> CLICommand {
        guard let subcommand = args.first else {
            throw CLIArgumentParseError.missingRequiredArgument("proxy <status|restart>")
        }
        guard args.count == 1 else {
            let value = args[1]
            if value.hasPrefix("-") {
                throw CLIArgumentParseError.unknownOption(value)
            }
            throw CLIArgumentParseError.unknownCommand(value)
        }

        switch subcommand {
        case "status":
            return .proxy(ProxyCommand(action: .status))
        case "restart":
            return .proxy(ProxyCommand(action: .restart))
        default:
            throw CLIArgumentParseError.unknownCommand(subcommand)
        }
    }

    private static func parseRegisterCommand(_ args: [String]) throws -> CLICommand {
        var alias: String?
        var assetID: String?
        var remoteURLString: String?
        var headers: [String: String] = [:]

        var index = 0
        while index < args.count {
            let option = args[index]
            switch option {
            case "--alias":
                index += 1
                guard index < args.count else {
                    throw CLIArgumentParseError.missingValue(option)
                }
                alias = args[index]
                index += 1
            case "--asset-id":
                index += 1
                guard index < args.count else {
                    throw CLIArgumentParseError.missingValue(option)
                }
                assetID = args[index]
                index += 1
            case "--url", "--remote-url":
                index += 1
                guard index < args.count else {
                    throw CLIArgumentParseError.missingValue(option)
                }
                remoteURLString = args[index]
                index += 1
            case "--header":
                index += 1
                guard index < args.count else {
                    throw CLIArgumentParseError.missingValue(option)
                }
                let (key, value) = try parseHeader(args[index])
                headers[key] = value
                index += 1
            default:
                if option.hasPrefix("-") {
                    throw CLIArgumentParseError.unknownOption(option)
                }
                throw CLIArgumentParseError.unknownCommand(option)
            }
        }

        guard let alias, !alias.isEmpty else {
            throw CLIArgumentParseError.missingRequiredArgument("--alias")
        }
        guard let assetID, !assetID.isEmpty else {
            throw CLIArgumentParseError.missingRequiredArgument("--asset-id")
        }
        guard let remoteURLString, !remoteURLString.isEmpty else {
            throw CLIArgumentParseError.missingRequiredArgument("--url")
        }

        let remoteURL = try parseRemoteURL(remoteURLString)
        return .register(
            RegisterAssetCommand(
                alias: alias,
                assetID: assetID,
                remoteURL: remoteURL,
                headers: headers.isEmpty ? nil : headers
            )
        )
    }

    private static func parseListCommand(_ args: [String]) throws -> CLICommand {
        guard args.isEmpty else {
            let value = args[0]
            if value.hasPrefix("-") {
                throw CLIArgumentParseError.unknownOption(value)
            }
            throw CLIArgumentParseError.unknownCommand(value)
        }
        return .listAliases
    }

    static func parseRemoteURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw),
              let scheme = url.scheme,
              !scheme.isEmpty,
              let host = url.host,
              !host.isEmpty else {
            throw CLIArgumentParseError.invalidURL(raw)
        }
        return url
    }

    static func parseHeader(_ raw: String) throws -> (String, String) {
        let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw CLIArgumentParseError.invalidHeader(raw)
        }

        let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else {
            throw CLIArgumentParseError.invalidHeader(raw)
        }
        return (key, value)
    }

    private static func parseClearDataCommand(_ args: [String]) throws -> CLICommand {
        var alias: String?
        var clearAll = false
        var removeAliasMetadata = false
        var bypassConfirmation = false

        var index = 0
        while index < args.count {
            let option = args[index]
            switch option {
            case "--alias":
                index += 1
                guard index < args.count else {
                    throw CLIArgumentParseError.missingValue(option)
                }
                alias = args[index]
                index += 1
            case "--all":
                clearAll = true
                index += 1
            case "--delete-alias":
                removeAliasMetadata = true
                index += 1
            case "--yes":
                bypassConfirmation = true
                index += 1
            default:
                if option.hasPrefix("-") {
                    throw CLIArgumentParseError.unknownOption(option)
                }
                throw CLIArgumentParseError.unknownCommand(option)
            }
        }

        guard !clearAll || alias == nil else {
            throw CLIArgumentParseError.invalidArgument("use either --alias <alias> or --all, not both")
        }

        let scope: ClearDataScope
        if let alias, !alias.isEmpty {
            scope = .alias(alias)
        } else if clearAll {
            scope = .all
        } else {
            throw CLIArgumentParseError.missingRequiredArgument("--alias <alias> or --all")
        }

        return .clearData(
            ClearDataCommand(
                scope: scope,
                removeAliasMetadata: removeAliasMetadata,
                bypassConfirmation: bypassConfirmation
            )
        )
    }

    private static func parseExportCommand(_ args: [String]) throws -> CLICommand {
        var alias: String?
        var output: String?
        var av1Enabled = false
        var av1Preset: String?
        var av1CRF: Int?
        var av1Bitrate: String?

        var index = 0
        while index < args.count {
            let option = args[index]
            switch option {
            case "--alias":
                index += 1
                guard index < args.count else {
                    throw CLIArgumentParseError.missingValue(option)
                }
                alias = args[index]
                index += 1
            case "--output":
                index += 1
                guard index < args.count else {
                    throw CLIArgumentParseError.missingValue(option)
                }
                output = args[index]
                index += 1
            case "--av1":
                av1Enabled = true
                index += 1
            case "--av1-preset":
                index += 1
                guard index < args.count else {
                    throw CLIArgumentParseError.missingValue(option)
                }
                let value = args[index].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw CLIArgumentParseError.invalidArgument("AV1 preset must not be empty")
                }
                av1Preset = value
                index += 1
            case "--av1-crf":
                index += 1
                guard index < args.count else {
                    throw CLIArgumentParseError.missingValue(option)
                }
                let value = args[index]
                guard let parsed = Int(value), (0...63).contains(parsed) else {
                    throw CLIArgumentParseError.invalidArgument("AV1 CRF must be an integer between 0 and 63")
                }
                av1CRF = parsed
                index += 1
            case "--av1-bitrate":
                index += 1
                guard index < args.count else {
                    throw CLIArgumentParseError.missingValue(option)
                }
                av1Bitrate = try parseAV1Bitrate(args[index])
                index += 1
            default:
                if option.hasPrefix("-") {
                    throw CLIArgumentParseError.unknownOption(option)
                }
                throw CLIArgumentParseError.unknownCommand(option)
            }
        }

        guard let alias, !alias.isEmpty else {
            throw CLIArgumentParseError.missingRequiredArgument("--alias")
        }
        guard let output, !output.isEmpty else {
            throw CLIArgumentParseError.missingRequiredArgument("--output")
        }

        if !av1Enabled, av1Preset != nil || av1CRF != nil || av1Bitrate != nil {
            throw CLIArgumentParseError.invalidArgument("AV1 tuning flags require --av1")
        }

        let videoCodec: ExportVideoCodec
        if av1Enabled {
            videoCodec = .av1(
                AV1TranscodeOptions(
                    preset: av1Preset ?? AV1TranscodeOptions.defaultPreset,
                    crf: av1CRF ?? AV1TranscodeOptions.defaultCRF,
                    bitrate: av1Bitrate
                )
            )
        } else {
            videoCodec = .copy
        }

        return .exportMP4(
            ExportMP4Command(
                alias: alias,
                outputURL: URL(fileURLWithPath: output).standardizedFileURL,
                videoCodec: videoCodec
            )
        )
    }

    private static func parseAV1Bitrate(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw CLIArgumentParseError.invalidArgument("AV1 bitrate must not be empty")
        }
        guard isValidAV1Bitrate(value) else {
            throw CLIArgumentParseError.invalidArgument(
                "Invalid AV1 bitrate '\(raw)'. Use a positive integer plus unit suffix k or M (examples: 1200k, 2M)."
            )
        }
        return value
    }

    private static func isValidAV1Bitrate(_ value: String) -> Bool {
        value.range(of: "^[1-9][0-9]*[kKmM]$", options: .regularExpression) != nil
    }

    private static func parseSettingsCommand(_ args: [String]) throws -> CLICommand {
        guard let subcommand = args.first else {
            throw CLIArgumentParseError.missingRequiredArgument("settings <get|set>")
        }

        switch subcommand {
        case "get":
            if args.count != 1 {
                throw CLIArgumentParseError.unknownCommand(args[1])
            }
            return .settingsGet
        case "set":
            guard args.count >= 3 else {
                throw CLIArgumentParseError.missingRequiredArgument("settings set default-user-agent <value>")
            }

            let key = args[1]
            guard key == "default-user-agent" else {
                throw CLIArgumentParseError.unknownCommand(key)
            }

            let rawValue = args.dropFirst(2).joined(separator: " ")
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw CLIArgumentParseError.invalidSettingValue("default-user-agent")
            }
            return .settingsSetDefaultUserAgent(value)
        default:
            throw CLIArgumentParseError.unknownCommand(subcommand)
        }
    }
}

enum CLIOutputFormat: String, Equatable {
    case text
    case json
}
