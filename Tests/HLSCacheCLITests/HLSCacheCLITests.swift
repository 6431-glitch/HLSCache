import CoreCache
import Foundation
import HLSCache
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

    func resetOutput() {
        outputLines.removeAll()
    }
}

private func makeCLITempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-cli-tests")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func seedCacheBytes(baseDirectory: URL, alias: String, assetID: String) throws {
    let facade = HLSCacheFacade(baseDirectory: baseDirectory)
    let record = try facade.register(
        alias: alias,
        assetID: assetID,
        remoteURL: try #require(URL(string: "https://cdn.example.com/\(alias).m3u8"))
    )

    let coreCache = CoreCache(baseDirectory: baseDirectory)
    let resource = ResourceID(
        cacheKey: record.cacheKey,
        kind: .segment,
        resourceKey: ResourceID.makeResourceKey(from: "https://cdn.example.com/\(alias)-seg-1.ts")
    )
    _ = try coreCache.write(Data(repeating: 7, count: 256), resource: resource, at: 0)
    _ = try coreCache.finalizeWrite(resource: resource, expectedLength: 256)
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

@Test func cliArguments_parseSettingsGetCommand() throws {
    let parsed = try CLIArguments.parse(["settings", "get"])
    #expect(parsed.command == .settingsGet)
}

@Test func cliArguments_parseSettingsSetDefaultUserAgentCommand() throws {
    let parsed = try CLIArguments.parse(["settings", "set", "default-user-agent", "Mozilla/5.0 (HLSCacheCLI)"])
    #expect(parsed.command == .settingsSetDefaultUserAgent("Mozilla/5.0 (HLSCacheCLI)"))
}

@Test func cliArguments_parseSettingsSetDefaultUserAgent_missingValue_throws() throws {
    do {
        _ = try CLIArguments.parse(["settings", "set", "default-user-agent"])
        #expect(Bool(false))
    } catch let error as CLIArgumentParseError {
        #expect(error == .missingRequiredArgument("settings set default-user-agent <value>"))
    }
}

@Test func cliArguments_parseClearDataCommand_withAliasDeleteAndYes() throws {
    let parsed = try CLIArguments.parse(["clear", "--alias", "MDCLR1", "--delete-alias", "--yes"])
    #expect(
        parsed.command == .clearData(
            ClearDataCommand(
                scope: .alias("MDCLR1"),
                removeAliasMetadata: true,
                bypassConfirmation: true
            )
        )
    )
}

@Test func cliArguments_parseClearDataCommand_missingScope_throws() throws {
    do {
        _ = try CLIArguments.parse(["clear", "--yes"])
        #expect(Bool(false))
    } catch let error as CLIArgumentParseError {
        #expect(error == .missingRequiredArgument("--alias <alias> or --all"))
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

@Test func cliSettingsCommands_setAndGet_persistAcrossContextRestarts() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let firstContext = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let firstIO = FakeIO(inputs: [])
    let firstApp = CLIApp(context: firstContext, io: firstIO)

    let setExitCode = firstApp.run(command: .settingsSetDefaultUserAgent("MyCLI/1.0"))
    #expect(setExitCode == 0)
    #expect(firstIO.outputLines.contains { $0.contains("Settings updated.") })
    #expect(firstIO.outputLines.contains { $0.contains("defaultUserAgent: MyCLI/1.0") })

    let secondContext = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let secondIO = FakeIO(inputs: [])
    let secondApp = CLIApp(context: secondContext, io: secondIO)
    let getExitCode = secondApp.run(command: .settingsGet)

    #expect(getExitCode == 0)
    #expect(secondIO.outputLines.contains { $0.contains("Settings file:") })
    #expect(secondIO.outputLines.contains { $0.contains("defaultUserAgent: MyCLI/1.0") })
}

@Test func cliSettingsSetCommand_emptyValue_printsValidationError() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let io = FakeIO(inputs: [])
    let app = CLIApp(context: context, io: io)

    let exitCode = app.run(command: .settingsSetDefaultUserAgent("   "))
    #expect(exitCode == 1)
    #expect(io.outputLines.contains { $0.contains("Invalid value for default-user-agent") })
}

@Test func cliRegisterCommand_appliesDefaultUserAgentWhenHeaderMissing() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let io = FakeIO(inputs: [])
    let app = CLIApp(context: context, io: io)

    #expect(app.run(command: .settingsSetDefaultUserAgent("GlobalUA/1.0")) == 0)
    io.resetOutput()

    let command = RegisterAssetCommand(
        alias: "MDUA100",
        assetID: "asset-ua-100",
        remoteURL: try #require(URL(string: "https://cdn.example.com/ua/master.m3u8")),
        headers: nil
    )
    #expect(app.run(command: .register(command)) == 0)
    #expect(io.outputLines.contains { $0.contains("User-Agent: GlobalUA/1.0") })
}

@Test func cliRegisterCommand_explicitUserAgentOverridesDefault() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let io = FakeIO(inputs: [])
    let app = CLIApp(context: context, io: io)

    #expect(app.run(command: .settingsSetDefaultUserAgent("GlobalUA/1.0")) == 0)
    io.resetOutput()

    let command = RegisterAssetCommand(
        alias: "MDUA200",
        assetID: "asset-ua-200",
        remoteURL: try #require(URL(string: "https://cdn.example.com/ua/override.m3u8")),
        headers: ["User-Agent": "AliasUA/2.0"]
    )
    #expect(app.run(command: .register(command)) == 0)
    #expect(io.outputLines.contains { $0.contains("User-Agent: AliasUA/2.0") })
    #expect(!io.outputLines.contains { $0.contains("User-Agent: GlobalUA/1.0") })
}

@Test func cliRegisterCommand_updatesAliasHeadersWithoutMutatingGlobalSettings() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let io = FakeIO(inputs: [])
    let app = CLIApp(context: context, io: io)

    #expect(app.run(command: .settingsSetDefaultUserAgent("GlobalUA/1.0")) == 0)
    io.resetOutput()

    let first = RegisterAssetCommand(
        alias: "MDUA300",
        assetID: "asset-ua-300",
        remoteURL: try #require(URL(string: "https://cdn.example.com/ua/update-1.m3u8")),
        headers: ["User-Agent": "AliasUA/1.0"]
    )
    #expect(app.run(command: .register(first)) == 0)

    let second = RegisterAssetCommand(
        alias: "MDUA300",
        assetID: "asset-ua-300",
        remoteURL: try #require(URL(string: "https://cdn.example.com/ua/update-2.m3u8")),
        headers: ["X-Test": "1"]
    )
    #expect(app.run(command: .register(second)) == 0)

    io.resetOutput()
    #expect(app.run(command: .settingsGet) == 0)
    #expect(io.outputLines.contains { $0.contains("defaultUserAgent: GlobalUA/1.0") })
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

@Test func cliClearCommand_requiresYesFlag_forNonInteractiveExecution() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedCacheBytes(baseDirectory: directory, alias: "MDNOYES", assetID: "asset-no-yes")

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let io = FakeIO(inputs: [])
    let app = CLIApp(context: context, io: io)

    let exitCode = app.run(
        command: .clearData(
            ClearDataCommand(scope: .alias("MDNOYES"), removeAliasMetadata: false, bypassConfirmation: false)
        )
    )

    #expect(exitCode == 1)
    #expect(io.outputLines.contains { $0.contains("Re-run with --yes") })
    #expect(context.facade.listAliases().contains { $0.alias == "MDNOYES" })
    let info = try context.facade.cacheInfo(alias: "MDNOYES")
    #expect(info.totalBytesOnDisk > 0)
}

@Test func cliClearCommand_aliasWithDelete_removesCacheAndMetadata() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedCacheBytes(baseDirectory: directory, alias: "MDCLR2", assetID: "asset-clr-2")

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let io = FakeIO(inputs: [])
    let app = CLIApp(context: context, io: io)

    let exitCode = app.run(
        command: .clearData(
            ClearDataCommand(scope: .alias("MDCLR2"), removeAliasMetadata: true, bypassConfirmation: true)
        )
    )

    #expect(exitCode == 0)
    #expect(io.outputLines.contains { $0.contains("Cleared cache for alias 'MDCLR2'.") })
    #expect(io.outputLines.contains { $0.contains("Alias metadata removed for 'MDCLR2'.") })
    #expect(io.outputLines.contains { $0.contains("Alias state: removed") })
    #expect(!context.facade.listAliases().contains { $0.alias == "MDCLR2" })
}

@Test func cliInteractiveCacheClear_promptsAndCanCancel() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedCacheBytes(baseDirectory: directory, alias: "MDCANCEL", assetID: "asset-cancel")

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let io = FakeIO(inputs: [
        "4", // Cache operations
        "1", // Clear by alias
        "MDCANCEL",
        "n", // Do not delete alias metadata
        "no", // Cancel destructive confirmation
        "0", // back
        "0" // exit
    ])
    let app = CLIApp(context: context, io: io)
    app.runInteractive()

    #expect(io.outputLines.contains { $0.contains("[Cache Operations]") })
    #expect(io.outputLines.contains { $0.contains("Type '--yes' to confirm") })
    #expect(io.outputLines.contains { $0.contains("Clear operation cancelled.") })

    let info = try context.facade.cacheInfo(alias: "MDCANCEL")
    #expect(info.totalBytesOnDisk > 0)
}

@Test func cliAssetManagement_listAliases_showsMetadataAndQReturnsToMenu() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    _ = try context.facade.register(
        alias: "MDLIST1",
        assetID: "asset-list-1",
        remoteURL: try #require(URL(string: "https://cdn.example.com/list-1.m3u8"))
    )

    let io = FakeIO(inputs: [
        "1", // Asset management
        "2", // List aliases
        "q", // Return from list
        "0", // Back from asset management
        "0" // Exit
    ])
    let app = CLIApp(context: context, io: io)
    app.runInteractive()

    #expect(io.outputLines.contains { $0.contains("[Alias List]") })
    #expect(io.outputLines.contains { $0.contains("MDLIST1 | assetID=asset-list-1") })
    #expect(io.outputLines.contains { $0.contains("remote=https://cdn.example.com/list-1.m3u8") })
    #expect(io.outputLines.contains { $0.contains("Main Menu") })
}

@Test func cliAssetManagement_listAliases_enterRefreshesWithoutNestedLoops() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    _ = try context.facade.register(
        alias: "MDLIST2",
        assetID: "asset-list-2",
        remoteURL: try #require(URL(string: "https://cdn.example.com/list-2.m3u8"))
    )

    let io = FakeIO(inputs: [
        "1", // Asset management
        "2", // List aliases
        "", // Refresh list
        "q", // Return from list
        "0", // Back from asset management
        "0" // Exit
    ])
    let app = CLIApp(context: context, io: io)
    app.runInteractive()

    let listHeaderCount = io.outputLines.filter { $0 == "[Alias List]" }.count
    #expect(listHeaderCount >= 2)
    #expect(io.outputLines.contains { $0.contains("Press Enter to refresh, or q to return.") })
    #expect(io.outputLines.contains { $0.contains("Goodbye.") })
}
