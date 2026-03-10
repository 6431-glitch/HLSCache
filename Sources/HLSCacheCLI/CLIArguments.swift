import Foundation

enum CLIArgumentParseError: Error, Equatable {
    case missingValue(String)
    case invalidPort(String)
    case unknownOption(String)
}

extension CLIArgumentParseError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .missingValue(option):
            return "Missing value for option '\(option)'."
        case let .invalidPort(value):
            return "Invalid port '\(value)'. Port must be an integer between 1 and 65535."
        case let .unknownOption(option):
            return "Unknown option '\(option)'."
        }
    }
}

struct CLIArguments: Equatable {
    static let defaultHost = "127.0.0.1"
    static let defaultPort = 8080

    let baseDirectory: URL?
    let host: String
    let port: Int
    let showHelp: Bool

    init(
        baseDirectory: URL? = nil,
        host: String = CLIArguments.defaultHost,
        port: Int = CLIArguments.defaultPort,
        showHelp: Bool = false
    ) {
        self.baseDirectory = baseDirectory
        self.host = host
        self.port = port
        self.showHelp = showHelp
    }

    static func parse(_ args: [String]) throws -> CLIArguments {
        var baseDirectory: URL?
        var host = defaultHost
        var port = defaultPort
        var showHelp = false

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
            default:
                throw CLIArgumentParseError.unknownOption(option)
            }
        }

        return CLIArguments(
            baseDirectory: baseDirectory,
            host: host,
            port: port,
            showHelp: showHelp
        )
    }

    static var usage: String {
        """
        Usage: swift run HLSCacheCLI [options]

        Options:
          --base-directory <path>   Base directory for cache and settings storage.
          --host <host>             Proxy host (default: \(defaultHost)).
          --port <port>             Proxy port (default: \(defaultPort)).
          --help, -h                Show this help message.
        """
    }
}
