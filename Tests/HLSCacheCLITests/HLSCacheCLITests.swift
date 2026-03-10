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
    #expect(parsed.command == .interactive)
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

@Test func cliArguments_parseRegisterCommand_withHeaders() throws {
    let parsed = try CLIArguments.parse([
        "add",
        "--alias", "MD0534",
        "--asset-id", "asset-0534",
        "--url", "https://cdn.example.com/master.m3u8",
        "--header", "Authorization: Bearer abc",
        "--header", "X-Region: us-east-1"
    ])

    let remoteURL = try #require(URL(string: "https://cdn.example.com/master.m3u8"))
    let expected = CLICommand.register(
        RegisterAssetCommand(
            alias: "MD0534",
            assetID: "asset-0534",
            remoteURL: remoteURL,
            headers: [
                "Authorization": "Bearer abc",
                "X-Region": "us-east-1"
            ]
        )
    )
    #expect(parsed.command == expected)
}

@Test func cliArguments_parseRegisterCommand_missingAlias_throws() throws {
    do {
        _ = try CLIArguments.parse([
            "register",
            "--asset-id", "asset-0534",
            "--url", "https://cdn.example.com/master.m3u8"
        ])
        #expect(Bool(false))
    } catch let error as CLIArgumentParseError {
        #expect(error == .missingRequiredArgument("--alias"))
    }
}

@Test func cliArguments_parseRegisterCommand_invalidURL_throws() throws {
    do {
        _ = try CLIArguments.parse([
            "add",
            "--alias", "MD0534",
            "--asset-id", "asset-0534",
            "--url", "not-a-url"
        ])
        #expect(Bool(false))
    } catch let error as CLIArgumentParseError {
        #expect(error == .invalidURL("not-a-url"))
    }
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

@Test func cliRegisterCommand_registersAsset_andShowsSummary() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let io = FakeIO(inputs: [])
    let app = CLIApp(context: context, io: io)

    let command = RegisterAssetCommand(
        alias: "MD9000",
        assetID: "asset-9000",
        remoteURL: try #require(URL(string: "https://cdn.example.com/v/master.m3u8")),
        headers: ["Authorization": "Bearer test"]
    )

    let exitCode = app.run(command: .register(command))
    #expect(exitCode == 0)
    #expect(io.outputLines.contains { $0.contains("Asset registered successfully.") })
    #expect(io.outputLines.contains { $0.contains("Alias: MD9000") })
    #expect(io.outputLines.contains { $0.contains("Cache Key:") })
    #expect(io.outputLines.contains { $0.contains("Remote URL: https://cdn.example.com/v/master.m3u8") })
}

@Test func cliAssetManagement_registerFlow_handlesMissingAndInvalidInputs() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let io = FakeIO(inputs: [
        "1", // Asset management
        "1", // Add/register asset
        "", // Missing alias
        "1", // Add/register asset again
        "MD1001",
        "asset-1001",
        "invalid-url",
        "1", // Add/register asset again with valid values
        "MD1001",
        "asset-1001",
        "https://cdn.example.com/video.m3u8",
        "Authorization: Bearer test",
        "", // end headers
        "0", // Back to main menu
        "0" // Exit app
    ])
    let app = CLIApp(context: context, io: io)
    app.runInteractive()

    #expect(io.outputLines.contains { $0.contains("Alias is required.") })
    #expect(io.outputLines.contains { $0.contains("Invalid URL 'invalid-url'") })
    #expect(io.outputLines.contains { $0.contains("Asset registered successfully.") })
}
