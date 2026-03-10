import Foundation
import Testing
@testable import HLSCacheCLI

private final class FakeIO: CLIIO {
    private var inputQueue: [String?]
    private(set) var outputLines: [String] = []

    init(inputs: [String?]) {
        self.inputQueue = inputs
    }

    func writeLine(_ text: String) {
        outputLines.append(text)
    }

    func readLine() -> String? {
        if inputQueue.isEmpty {
            return nil
        }
        return inputQueue.removeFirst()
    }
}

private func makeCLITempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-cli-tests")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func cliArguments_defaults_whenNoOptionsProvided() throws {
    let parsed = try CLIArguments.parse([])

    #expect(parsed.baseDirectory == nil)
    #expect(parsed.host == CLIArguments.defaultHost)
    #expect(parsed.port == CLIArguments.defaultPort)
    #expect(parsed.showHelp == false)
}

@Test func cliArguments_parsesBaseDirectoryHostPortAndHelp() throws {
    let path = "/tmp/hls-cli"
    let parsed = try CLIArguments.parse([
        "--base-directory", path,
        "--host", "0.0.0.0",
        "--port", "9090",
        "--help"
    ])

    #expect(parsed.baseDirectory == URL(fileURLWithPath: path).standardizedFileURL)
    #expect(parsed.host == "0.0.0.0")
    #expect(parsed.port == 9090)
    #expect(parsed.showHelp == true)
}

@Test func cliArguments_unknownOption_throws() throws {
    do {
        _ = try CLIArguments.parse(["--wat"])
        #expect(Bool(false))
    } catch let error as CLIArgumentParseError {
        #expect(error == .unknownOption("--wat"))
    }
}

@Test func cliArguments_invalidPort_throws() throws {
    do {
        _ = try CLIArguments.parse(["--port", "99999"])
        #expect(Bool(false))
    } catch let error as CLIArgumentParseError {
        #expect(error == .invalidPort("99999"))
    }
}

@Test func cliMainMenu_invalidInput_thenExit_showsErrorMessage() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let io = FakeIO(inputs: ["invalid", "0"])
    let app = CLIApp(context: context, io: io)
    app.runInteractive()

    #expect(io.outputLines.contains { $0.contains("Main Menu") })
    #expect(io.outputLines.contains { $0.contains("Invalid selection 'invalid'") })
    #expect(io.outputLines.contains { $0.contains("Goodbye.") })
}

@Test func cliMainMenu_routesToSubflow_andReturnsSafely() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let io = FakeIO(inputs: ["3", "1", "0", "0"])
    let app = CLIApp(context: context, io: io)
    app.runInteractive()

    #expect(io.outputLines.contains { $0.contains("[Settings]") })
    #expect(io.outputLines.contains { $0.contains("Settings file:") })
    #expect(io.outputLines.contains { $0.contains("Main Menu") })
    #expect(io.outputLines.contains { $0.contains("Goodbye.") })
}
