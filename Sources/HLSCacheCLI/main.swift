import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

do {
    let arguments = try CLIArguments.parse(Array(CommandLine.arguments.dropFirst()))
    if arguments.showHelp {
        print(CLIArguments.usage)
        exit(EXIT_SUCCESS)
    }

    let context = try CLIAppContext(arguments: arguments)
    let app = CLIApp(context: context)
    exit(app.run(command: arguments.command))
} catch let error as CLIArgumentParseError {
    fputs("Argument error: \(error.localizedDescription)\n\n", stderr)
    fputs(CLIArguments.usage + "\n", stderr)
    exit(EXIT_FAILURE)
} catch {
    fputs("Failed to start HLSCacheCLI: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
