import CoreCache
import Foundation
import HLSCache
import Testing
@testable import HLSCacheCLI

private final class FakeIO: CLIIO {
    private var inputQueue: [String?]
    private(set) var outputLines: [String] = []
    private(set) var errorLines: [String] = []

    init(inputs: [String?]) {
        self.inputQueue = inputs
    }

    func writeLine(_ text: String) {
        outputLines.append(text)
    }

    func writeErrorLine(_ text: String) {
        errorLines.append(text)
    }

    func readLine() -> String? {
        if inputQueue.isEmpty {
            return nil
        }
        return inputQueue.removeFirst()
    }

    func resetOutput() {
        outputLines.removeAll()
        errorLines.removeAll()
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

    let coreCache = try CoreCache(baseDirectory: baseDirectory)
    let resource = ResourceID(
        cacheKey: record.cacheKey,
        kind: .segment,
        resourceKey: ResourceID.makeResourceKey(from: "https://cdn.example.com/\(alias)-seg-1.ts")
    )
    _ = try coreCache.write(Data(repeating: 7, count: 256), resource: resource, at: 0)
    _ = try coreCache.finalizeWrite(resource: resource, expectedLength: 256)
}

private func makeFullCoverageRanges(length: Int64) -> IntervalSet {
    var ranges = IntervalSet()
    if let range = ByteRange(start: 0, endExclusive: length) {
        ranges.insert(range)
    }
    return ranges
}

private func seedExportableMediaCache(baseDirectory: URL, alias: String, assetID: String) throws {
    let facade = HLSCacheFacade(baseDirectory: baseDirectory)
    let playlistURL = try #require(URL(string: "https://cdn.example.com/\(alias)/media.m3u8"))
    let record = try facade.register(alias: alias, assetID: assetID, remoteURL: playlistURL)

    let playlist = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:8
    #EXTINF:8.0,
    seg-1.ts
    #EXTINF:8.0,
    seg-2.ts
    #EXT-X-ENDLIST
    """

    let manifestStore = ManifestStore(baseDirectory: baseDirectory)
    let diskStore = DiskStore(baseDirectory: baseDirectory)

    let playlistResourceID = ResourceID(
        cacheKey: record.cacheKey,
        kind: .playlistM3U8,
        resourceKey: ResourceID.makeResourceKey(from: playlistURL)
    )
    let playlistData = Data(playlist.utf8)
    _ = try diskStore.write(playlistData, for: playlistResourceID, at: 0)
    try manifestStore.save(
        resourceID: playlistResourceID,
        record: ResourceRecord(
            kind: .playlistM3U8,
            originalURL: playlistURL,
            contentType: "application/vnd.apple.mpegurl",
            expectedLength: Int64(playlistData.count),
            completedRanges: makeFullCoverageRanges(length: Int64(playlistData.count))
        )
    )

    for (index, segmentName) in ["seg-1.ts", "seg-2.ts"].enumerated() {
        let segmentURL = playlistURL.deletingLastPathComponent().appendingPathComponent(segmentName)
        let payload = Data(repeating: UInt8(0x20 + index), count: 188)
        let resourceID = ResourceID(
            cacheKey: record.cacheKey,
            kind: .segment,
            resourceKey: ResourceID.makeResourceKey(from: segmentURL)
        )
        _ = try diskStore.write(payload, for: resourceID, at: 0)
        try manifestStore.save(
            resourceID: resourceID,
            record: ResourceRecord(
                kind: .segment,
                originalURL: segmentURL,
                contentType: "video/mp2t",
                expectedLength: Int64(payload.count),
                completedRanges: makeFullCoverageRanges(length: Int64(payload.count))
            )
        )
    }
}

private func loadRepositoryREADME() throws -> String {
    let testFileURL = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testFileURL
        .deletingLastPathComponent() // HLSCacheCLITests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
    let readmeURL = repositoryRoot.appendingPathComponent("README.md")
    return try String(contentsOf: readmeURL, encoding: .utf8)
}

@Test func docs_readmeAndUsageStayAlignedWithImplementedCLI() throws {
    let readme = try loadRepositoryREADME()
    #expect(readme.contains("swift run HLSCacheCLI download --alias MD0534"))
    #expect(readme.contains("--av1"))
    #expect(readme.contains("AES-128 encrypted playlists are exportable when the referenced key material is already cached."))
    #expect(!readme.contains("AES-128 encrypted playlists are currently not supported by CLI export."))

    let usage = CLIArguments.usage.lowercased()
    #expect(usage.contains("download --alias <alias>"))
    #expect(usage.contains("export --alias <alias> --output <file.mp4> [--av1]"))
    #expect(!usage.contains("coming soon"))
    #expect(!usage.contains("placeholder"))
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

@Test func cliArguments_parseDownloadCommand_withAlias() throws {
    let parsed = try CLIArguments.parse(["download", "--alias", "MDDL01"])
    #expect(parsed.command == .download(DownloadCommand(alias: "MDDL01")))
}

@Test func cliArguments_parseListCommand() throws {
    let parsed = try CLIArguments.parse(["list"])
    #expect(parsed.command == .listAliases)
}

@Test func cliArguments_parseListCommand_withUnexpectedArgument_throws() throws {
    do {
        _ = try CLIArguments.parse(["list", "--alias", "MDLISTFAIL"])
        #expect(Bool(false))
    } catch let error as CLIArgumentParseError {
        #expect(error == .unknownOption("--alias"))
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

@Test func cliArguments_parseClearDataCommand_aliasAndAll_throws() throws {
    do {
        _ = try CLIArguments.parse(["clear", "--alias", "MDCONFLICT", "--all", "--yes"])
        #expect(Bool(false))
    } catch let error as CLIArgumentParseError {
        #expect(error == .invalidArgument("use either --alias <alias> or --all, not both"))
    }
}

@Test func cliArguments_parseExportCommand_withAliasAndOutput() throws {
    let parsed = try CLIArguments.parse(["export", "--alias", "MDEXPORT", "--output", "/tmp/output.mp4"])
    #expect(
        parsed.command == .exportMP4(
            ExportMP4Command(
                alias: "MDEXPORT",
                outputURL: URL(fileURLWithPath: "/tmp/output.mp4").standardizedFileURL
            )
        )
    )
}

@Test func cliArguments_parseExportCommand_withAV1Flags() throws {
    let parsed = try CLIArguments.parse([
        "export",
        "--alias", "MDEXPORT",
        "--output", "/tmp/output.mp4",
        "--av1",
        "--av1-preset", "8",
        "--av1-crf", "29",
        "--av1-bitrate", "1400k"
    ])

    #expect(
        parsed.command == .exportMP4(
            ExportMP4Command(
                alias: "MDEXPORT",
                outputURL: URL(fileURLWithPath: "/tmp/output.mp4").standardizedFileURL,
                videoCodec: .av1(
                    AV1TranscodeOptions(
                        preset: "8",
                        crf: 29,
                        bitrate: "1400k"
                    )
                )
            )
        )
    )
}

@Test func cliArguments_parseExportCommand_av1TuningWithoutMode_throws() throws {
    do {
        _ = try CLIArguments.parse([
            "export",
            "--alias", "MDEXPORT",
            "--output", "/tmp/output.mp4",
            "--av1-crf", "31"
        ])
        #expect(Bool(false))
    } catch let error as CLIArgumentParseError {
        #expect(error == .invalidArgument("AV1 tuning flags require --av1"))
    }
}

@Test func cliArguments_parseExportCommand_missingOutput_throws() throws {
    do {
        _ = try CLIArguments.parse(["export", "--alias", "MDEXPORT"])
        #expect(Bool(false))
    } catch let error as CLIArgumentParseError {
        #expect(error == .missingRequiredArgument("--output"))
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

@Test func cliProxyMenu_showsRuntimeActionsByDefault() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let io = FakeIO(inputs: ["2", "0", "0"])
    let app = CLIApp(context: context, io: io)
    app.runInteractive()

    #expect(io.outputLines.contains { $0.contains("[Proxy Server]") })
    #expect(io.outputLines.contains { $0.contains("1) Show proxy status") })
    #expect(io.outputLines.contains { $0.contains("2) Restart proxy server") })
    #expect(!io.outputLines.contains { $0.contains("disabled by feature flags") })
}

@Test func cliProxyMenu_statusAction_reportsRuntimeMetadataWhenRunning() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    _ = try context.facade.register(
        alias: "MDPROXY1",
        assetID: "asset-proxy-1",
        remoteURL: try #require(URL(string: "https://cdn.example.com/proxy-1.m3u8"))
    )

    let io = FakeIO(inputs: ["2", "1", "0", "0"])
    let app = CLIApp(context: context, io: io)
    app.runInteractive()

    #expect(io.outputLines.contains { $0.contains("[Proxy Server]") })
    #expect(io.outputLines.contains { $0.contains("Proxy status:") })
    #expect(io.outputLines.contains { $0.contains("State: running") })
    #expect(io.outputLines.contains { $0.contains("Host: 127.0.0.1") })
    #expect(io.outputLines.contains { $0.contains("Port: \(context.serverBaseURL.port.map(String.init) ?? "(unavailable)")") })
    #expect(io.outputLines.contains { $0.contains("Base URL: \(context.serverBaseURL.absoluteString)") })
    #expect(io.outputLines.contains { $0.contains("Registered aliases: 1") })
}

@Test func cliProxyMenu_statusAction_whenProxyUnavailable_isExplicitAndNonCrashing() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    context.facade.stopServer()

    let io = FakeIO(inputs: ["2", "1", "0", "0"])
    let app = CLIApp(context: context, io: io)
    app.runInteractive()

    #expect(io.outputLines.contains { $0.contains("Proxy base URL: (unavailable)") })
    #expect(io.outputLines.contains { $0.contains("Proxy status:") })
    #expect(io.outputLines.contains { $0.contains("State: stopped") })
    #expect(io.outputLines.contains { $0.contains("Host: (unavailable)") })
    #expect(io.outputLines.contains { $0.contains("Port: (unavailable)") })
    #expect(io.outputLines.contains { $0.contains("Base URL: (unavailable)") })
    #expect(io.outputLines.contains { $0.contains("Proxy server is not running.") })
    #expect(io.outputLines.contains { $0.contains("Goodbye.") })
}

@Test func cliProxyMenu_restartAction_reportsBeforeAndAfterStatusContext() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let io = FakeIO(inputs: ["2", "2", "0", "0"])
    let app = CLIApp(context: context, io: io)
    app.runInteractive()

    #expect(io.outputLines.contains { $0.contains("Restarting proxy server...") })
    #expect(io.outputLines.contains { $0.contains("Before restart:") })
    #expect(io.outputLines.contains { $0.contains("After restart:") })
    #expect(io.outputLines.contains { $0.contains("Proxy server restarted.") })
    #expect(io.outputLines.contains { $0.hasPrefix("Resolved base URL: http://127.0.0.1:") })

    let runningStateCount = io.outputLines.filter { $0 == "State: running" }.count
    #expect(runningStateCount >= 2)
}

@Test func cliProxyMenu_restartAction_whenInitiallyStopped_showsStoppedThenRunning() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    context.facade.stopServer()

    let io = FakeIO(inputs: ["2", "2", "0", "0"])
    let app = CLIApp(context: context, io: io)
    app.runInteractive()

    #expect(io.outputLines.contains { $0.contains("Before restart:") })
    #expect(io.outputLines.contains { $0.contains("State: stopped") })
    #expect(io.outputLines.contains { $0.contains("After restart:") })
    #expect(io.outputLines.contains { $0.contains("State: running") })
    #expect(io.outputLines.contains { $0.hasPrefix("Resolved base URL: http://127.0.0.1:") })
}

@Test func cliProxyMenu_returnBehavior_supportsBackAndQToMainMenu() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let io = FakeIO(inputs: [
        "2", // Enter proxy menu
        "back", // Return to main
        "2", // Enter proxy menu again
        "q", // Return to main using q
        "0" // Exit app
    ])
    let app = CLIApp(context: context, io: io)
    app.runInteractive()

    let proxyMenuCount = io.outputLines.filter { $0 == "[Proxy Server]" }.count
    #expect(proxyMenuCount == 2)
    #expect(io.outputLines.contains { $0.contains("Main Menu") })
    #expect(io.outputLines.contains { $0.contains("Goodbye.") })
}

@Test func cliProxyMenu_integration_flow_validatesPromptsAndNoPlaceholderRegression() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let io = FakeIO(inputs: [
        "2", // Enter proxy menu
        "1", // Show status
        "2", // Restart
        "0", // Back to main menu
        "0" // Exit app
    ])
    let app = CLIApp(context: context, io: io)
    app.runInteractive()

    #expect(io.outputLines.contains { $0.contains("[Proxy Server]") })
    #expect(io.outputLines.contains { $0.contains("1) Show proxy status") })
    #expect(io.outputLines.contains { $0.contains("2) Restart proxy server") })
    #expect(io.outputLines.contains { $0.contains("Choose an option:") })
    #expect(io.outputLines.contains { $0.contains("Proxy status:") })
    #expect(io.outputLines.contains { $0.contains("Proxy server restarted.") })
    #expect(!io.outputLines.contains { $0.localizedCaseInsensitiveContains("coming soon") })
    #expect(!io.outputLines.contains { $0.localizedCaseInsensitiveContains("not implemented yet") })
    #expect(io.outputLines.contains { $0.contains("Goodbye.") })
}

@Test func cliProxyMenu_e2e_statusBeforeAndAfterRestart_reportsStableTransitions() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    _ = try context.facade.register(
        alias: "MDE2E1",
        assetID: "asset-e2e-1",
        remoteURL: try #require(URL(string: "https://cdn.example.com/e2e-1.m3u8"))
    )

    let io = FakeIO(inputs: [
        "2", // Proxy menu
        "1", // Status before restart
        "2", // Restart
        "1", // Status after restart
        "0", // Back
        "0" // Exit
    ])
    let app = CLIApp(context: context, io: io)
    app.runInteractive()

    let proxyStatusCount = io.outputLines.filter { $0 == "Proxy status:" }.count
    #expect(proxyStatusCount >= 2)
    #expect(io.outputLines.contains { $0.contains("Proxy server restarted.") })
    #expect(io.outputLines.contains { $0.contains("Before restart:") })
    #expect(io.outputLines.contains { $0.contains("After restart:") })
    #expect(io.outputLines.contains { $0.contains("Registered aliases: 1") })
    #expect(io.outputLines.contains { $0.contains("Goodbye.") })
}

@Test func cliProxyMenu_e2e_restartFailurePath_printsActionableErrorAndDoesNotCrash() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let runningURL = try #require(URL(string: "http://127.0.0.1:8080"))
    var status = ProxyServerStatus(
        isRunning: true,
        host: "127.0.0.1",
        port: 8080,
        baseURL: runningURL
    )

    let io = FakeIO(inputs: [
        "2", // Proxy menu
        "2", // Restart
        "0", // Back
        "0" // Exit
    ])
    let app = CLIApp(
        context: context,
        io: io,
        proxyStatusProvider: { status },
        stopProxyServer: {
            status = ProxyServerStatus(isRunning: false, host: nil, port: nil, baseURL: nil)
        },
        startProxyServer: { host, port in
            // Simulate startup API returning a URL while runtime remains unavailable.
            status = ProxyServerStatus(isRunning: false, host: nil, port: nil, baseURL: nil)
            return URL(string: "http://\(host):\(port)")!
        }
    )
    app.runInteractive()

    #expect(io.outputLines.contains { $0.contains("Failed to restart proxy server.") })
    #expect(io.outputLines.contains { $0.contains("Attempted host: 127.0.0.1") })
    #expect(io.outputLines.contains { $0.contains("Attempted port: 8080") })
    #expect(io.outputLines.contains { $0.contains("Action: verify runtime configuration and try again.") })
    #expect(io.outputLines.contains { $0.contains("Goodbye.") })
}

@Test func cliInteractive_containsNoPlaceholderText() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let io = FakeIO(inputs: ["1", "0", "2", "0", "4", "0", "0"])
    let app = CLIApp(context: context, io: io)
    app.runInteractive()

    #expect(!io.outputLines.contains { $0.localizedCaseInsensitiveContains("coming soon") })
    #expect(!io.outputLines.contains { $0.localizedCaseInsensitiveContains("not implemented yet") })
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

@Test func cliSettingsStore_corruptedJSON_isQuarantinedAndReported() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let settingsFileURL = directory.appendingPathComponent("cli_settings.json")
    try Data("{invalid-json".utf8).write(to: settingsFileURL)

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let io = FakeIO(inputs: [])
    let app = CLIApp(context: context, io: io)

    let exitCode = app.run(command: .settingsGet)
    #expect(exitCode == 0)

    let corruptFileURL = settingsFileURL.appendingPathExtension("corrupt")
    #expect(FileManager.default.fileExists(atPath: settingsFileURL.path))
    #expect(FileManager.default.fileExists(atPath: corruptFileURL.path))
    #expect(io.outputLines.contains { $0.contains("Settings recovery warning (recovered_decode_failure)") })
    #expect(io.outputLines.contains { $0.contains("Recovery action: quarantine_and_reset") })
    #expect(io.outputLines.contains { $0.contains("Settings file: \(settingsFileURL.path)") })
    #expect(io.outputLines.contains { $0.contains("Recovery file: \(corruptFileURL.path)") })
}

@Test func cliSettingsStore_partialFile_isQuarantinedAndReported() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let settingsFileURL = directory.appendingPathComponent("cli_settings.json")
    try Data("{\"defaultUserAgent\":\"partial".utf8).write(to: settingsFileURL)

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let io = FakeIO(inputs: [])
    let app = CLIApp(context: context, io: io)

    let exitCode = app.run(command: .settingsGet)
    #expect(exitCode == 0)

    let corruptFileURL = settingsFileURL.appendingPathExtension("corrupt")
    #expect(FileManager.default.fileExists(atPath: corruptFileURL.path))
    #expect(io.outputLines.contains { $0.contains("Settings recovery warning (recovered_decode_failure)") })
    #expect(io.outputLines.contains { $0.contains("Recovery action: quarantine_and_reset") })
}

@Test func cliSettingsStore_recoveryStillAllowsFutureWrites() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let settingsFileURL = directory.appendingPathComponent("cli_settings.json")
    try Data("{broken".utf8).write(to: settingsFileURL)

    let firstContext = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let firstIO = FakeIO(inputs: [])
    let firstApp = CLIApp(context: firstContext, io: firstIO)
    #expect(firstApp.run(command: .settingsSetDefaultUserAgent("RecoveredUA/1.0")) == 0)
    #expect(firstIO.outputLines.contains { $0.contains("Settings recovery warning (recovered_decode_failure)") })

    let secondContext = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let secondIO = FakeIO(inputs: [])
    let secondApp = CLIApp(context: secondContext, io: secondIO)
    #expect(secondApp.run(command: .settingsGet) == 0)
    #expect(secondIO.outputLines.contains { $0.contains("defaultUserAgent: RecoveredUA/1.0") })
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

@Test func cliAssetManagement_listAliases_mixedHealthyAndDegradedStates_isExplicitAndResilient() throws {
    enum CacheMetadataFailure: Error { case unavailable }

    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    _ = try context.facade.register(
        alias: "MDLISTOK",
        assetID: "asset-list-ok",
        remoteURL: try #require(URL(string: "https://cdn.example.com/list-ok.m3u8"))
    )
    _ = try context.facade.register(
        alias: "MDLISTBAD",
        assetID: "asset-list-bad",
        remoteURL: try #require(URL(string: "https://cdn.example.com/list-bad.m3u8"))
    )

    let io = FakeIO(inputs: [
        "1", // Asset management
        "2", // List aliases
        "q", // Return from list
        "0", // Back from asset management
        "0" // Exit
    ])
    let app = CLIApp(
        context: context,
        io: io,
        cacheInfoProvider: { alias in
            if alias == "MDLISTBAD" {
                throw CacheMetadataFailure.unavailable
            }
            return try context.facade.cacheInfo(alias: alias)
        }
    )

    app.runInteractive()

    #expect(io.outputLines.contains { $0.contains("MDLISTOK | assetID=asset-list-ok | bytes=") })
    #expect(io.outputLines.contains { $0.contains("MDLISTBAD | assetID=asset-list-bad | bytes=(degraded)") })
    #expect(io.outputLines.contains { $0.contains("cache_status=metadata_error") })
    #expect(io.outputLines.contains { $0.contains("cache_error=") })
    #expect(io.outputLines.contains { $0.contains("remote=https://cdn.example.com/list-bad.m3u8") })
    #expect(io.outputLines.contains { $0.contains("Main Menu") })
}

@Test func cliListCommand_nonInteractive_printsAliasInventoryFields() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedCacheBytes(baseDirectory: directory, alias: "MDLISTCLI", assetID: "asset-list-cli")

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let io = FakeIO(inputs: [])
    let app = CLIApp(context: context, io: io)

    let exitCode = app.run(command: .listAliases)

    #expect(exitCode == 0)
    #expect(io.outputLines.contains { $0.contains("MDLISTCLI | assetID=asset-list-cli | bytes=") })
    #expect(io.outputLines.contains { $0.contains("updated=") })
    #expect(io.outputLines.contains { $0.contains("remote=https://cdn.example.com/MDLISTCLI.m3u8") })
    #expect(io.errorLines.isEmpty)
}

@Test func cliListCommand_nonInteractive_mixedStateRemainsStrictAndFails() throws {
    enum CacheMetadataFailure: Error { case unavailable }

    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    _ = try context.facade.register(
        alias: "MDSTRICTOK",
        assetID: "asset-strict-ok",
        remoteURL: try #require(URL(string: "https://cdn.example.com/strict-ok.m3u8"))
    )
    _ = try context.facade.register(
        alias: "MDSTRICTBAD",
        assetID: "asset-strict-bad",
        remoteURL: try #require(URL(string: "https://cdn.example.com/strict-bad.m3u8"))
    )

    let io = FakeIO(inputs: [])
    let app = CLIApp(
        context: context,
        io: io,
        cacheInfoProvider: { alias in
            if alias == "MDSTRICTBAD" {
                throw CacheMetadataFailure.unavailable
            }
            return try context.facade.cacheInfo(alias: alias)
        }
    )

    let exitCode = app.run(command: .listAliases)

    #expect(exitCode == 1)
    #expect(io.errorLines.contains { $0.contains("Failed to list aliases:") })
}

@Test func cliListCommand_nonInteractive_whenNoAliases_printsEmptyState() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let io = FakeIO(inputs: [])
    let app = CLIApp(context: context, io: io)

    let exitCode = app.run(command: .listAliases)

    #expect(exitCode == 0)
    #expect(io.outputLines == ["(no aliases registered)"])
    #expect(io.errorLines.isEmpty)
}

@Test func cliExportCommand_runsThroughCLIApp_andPrintsOutputSummary() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try seedExportableMediaCache(baseDirectory: directory, alias: "MDEXPCLI", assetID: "asset-exp-cli")

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let outputURL = directory.appendingPathComponent("out/video.mp4")
    let io = FakeIO(inputs: [])
    let app = CLIApp(
        context: context,
        io: io,
        makeExporter: { appContext in
            CLIExporter(
                baseDirectory: appContext.baseDirectory,
                facade: appContext.facade,
                exportRunner: { _, outputURL, _ in
                    try FileManager.default.createDirectory(
                        at: outputURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try Data("mp4bytes".utf8).write(to: outputURL)
                }
            )
        }
    )

    let exitCode = app.run(
        command: .exportMP4(
            ExportMP4Command(alias: "MDEXPCLI", outputURL: outputURL)
        )
    )

    #expect(exitCode == 0)
    #expect(io.outputLines.contains { $0.contains("Export progress:") })
    #expect(io.outputLines.contains { $0.contains("phase encoding") })
    #expect(io.outputLines.contains { $0.contains("Export completed successfully.") })
    #expect(io.outputLines.contains { $0.contains("Export completed in ") })
    #expect(io.outputLines.contains { $0.contains("Alias: MDEXPCLI") })
    #expect(io.outputLines.contains { $0.contains("Video mode: remux (copy)") })
    #expect(io.outputLines.contains { $0.contains("Output: \(outputURL.path)") })
    #expect(io.outputLines.contains { $0.contains("Output size: 8 bytes") })
}

@Test func cliDownloadCommand_runsThroughCLIApp_andPrintsProgressSummary() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    _ = try context.facade.register(
        alias: "MDDLPROG",
        assetID: "asset-download-progress",
        remoteURL: try #require(URL(string: "https://cdn.example.com/progress/media.m3u8"))
    )

    let io = FakeIO(inputs: [])
    let app = CLIApp(
        context: context,
        io: io,
        makeDownloader: { appContext in
            CLIHLSDownloader(
                baseDirectory: appContext.baseDirectory,
                facade: appContext.facade,
                fetcher: { request in
                    let url = try #require(request.url)
                    let body: Data
                    let contentType: String

                    switch url.absoluteString {
                    case "https://cdn.example.com/progress/media.m3u8":
                        body = Data(
                            """
                            #EXTM3U
                            #EXT-X-VERSION:3
                            #EXT-X-TARGETDURATION:8
                            #EXTINF:8.0,
                            seg-1.ts
                            #EXTINF:8.0,
                            seg-2.ts
                            #EXT-X-ENDLIST
                            """.utf8
                        )
                        contentType = "application/vnd.apple.mpegurl"
                    case "https://cdn.example.com/progress/seg-1.ts":
                        body = Data(repeating: 0x11, count: 188)
                        contentType = "video/mp2t"
                    case "https://cdn.example.com/progress/seg-2.ts":
                        body = Data(repeating: 0x22, count: 188)
                        contentType = "video/mp2t"
                    default:
                        throw CLIDownloadError.requestFailed(url: url, statusCode: 404, reason: "Not Found")
                    }

                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": contentType]
                    )!
                    return (body, response)
                }
            )
        }
    )

    let exitCode = app.run(command: .download(DownloadCommand(alias: "MDDLPROG")))

    #expect(exitCode == 0)
    #expect(io.outputLines.contains { $0.contains("Download plan: playlists 1 (media 1) | segments 2 | keys 0 | total resources 3") })
    #expect(io.outputLines.contains { $0.contains("Download progress:") })
    #expect(io.outputLines.contains { $0.contains("Download completed successfully.") })
    #expect(io.outputLines.contains { $0.contains("Download completed in ") })
    #expect(io.outputLines.contains { $0.contains("Alias: MDDLPROG") })
    #expect(io.outputLines.contains { $0.contains("Segments cached: 2") })
    #expect(io.outputLines.contains { $0.contains("Bytes written:") })
}

@Test func cliDownloadCommand_missingAliasPrintsActionableError() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let io = FakeIO(inputs: [])
    let app = CLIApp(context: context, io: io)

    let exitCode = app.run(command: .download(DownloadCommand(alias: "DOES_NOT_EXIST")))

    #expect(exitCode == 1)
    #expect(io.outputLines.contains { $0.contains("Alias 'DOES_NOT_EXIST' was not found.") })
}

@Test func cliHLSDownloader_timeoutError_usesConfiguredTimeoutAndTypedFailure() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let facade = HLSCacheFacade(baseDirectory: directory)
    let rootURL = try #require(URL(string: "https://cdn.example.com/timeout/master.m3u8"))
    _ = try facade.register(alias: "MDTIMEOUT", assetID: "asset-timeout", remoteURL: rootURL)

    var seenTimeout: TimeInterval = 0
    let downloader = CLIHLSDownloader(
        baseDirectory: directory,
        facade: facade,
        requestTimeout: 0.25,
        fetcher: { request in
            seenTimeout = request.timeoutInterval
            throw URLError(.timedOut)
        }
    )

    do {
        _ = try downloader.download(alias: "MDTIMEOUT")
        #expect(Bool(false))
    } catch let error as CLIDownloadError {
        switch error {
        case let .requestTimedOut(url, timeout):
            #expect(url == rootURL)
            #expect(timeout == 0.25)
            #expect(seenTimeout == 0.25)
        default:
            #expect(Bool(false))
        }
    }
}

@Test func cliHLSDownloader_cancellationChecker_stopsBeforeTransportFetch() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let facade = HLSCacheFacade(baseDirectory: directory)
    let rootURL = try #require(URL(string: "https://cdn.example.com/cancel/master.m3u8"))
    _ = try facade.register(alias: "MDCANCEL", assetID: "asset-cancel", remoteURL: rootURL)

    var fetchInvoked = false
    let downloader = CLIHLSDownloader(
        baseDirectory: directory,
        facade: facade,
        cancellationChecker: { true },
        fetcher: { request in
            fetchInvoked = true
            let response = try #require(
                HTTPURLResponse(
                    url: request.url ?? URL(fileURLWithPath: "/"),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )
            )
            return (Data(), response)
        }
    )

    do {
        _ = try downloader.download(alias: "MDCANCEL")
        #expect(Bool(false))
    } catch let error as CLIDownloadError {
        switch error {
        case let .requestCancelled(url):
            #expect(url == rootURL)
            #expect(fetchInvoked == false)
        default:
            #expect(Bool(false))
        }
    }
}

@Test func cliInteractive_quickstartFlow_coversCoreCommandsAndNavigation() throws {
    let directory = try makeCLITempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let context = try CLIAppContext(arguments: CLIArguments(baseDirectory: directory))
    let io = FakeIO(inputs: [
        "1", // Asset management
        "1", // Add/register asset
        "MDFLOW1",
        "asset-flow-1",
        "https://cdn.example.com/flow/master.m3u8",
        "", // No headers
        "2", // List aliases
        "q", // Return from list via q
        "0", // Back to main menu
        "3", // Settings
        "2", // Set default User-Agent
        "FlowUA/1.0",
        "1", // Show settings
        "0", // Back to main menu
        "4", // Cache operations
        "1", // Clear cache by alias
        "MDFLOW1",
        "n", // Keep alias metadata
        "--yes", // Confirm destructive operation
        "0", // Back to main menu
        "0" // Exit
    ])
    let app = CLIApp(context: context, io: io)
    app.runInteractive()

    #expect(io.outputLines.contains { $0.contains("Asset registered successfully.") })
    #expect(io.outputLines.contains { $0.contains("[Alias List]") })
    #expect(io.outputLines.contains { $0.contains("MDFLOW1 | assetID=asset-flow-1") })
    #expect(io.outputLines.contains { $0.contains("[Settings]") })
    #expect(io.outputLines.contains { $0.contains("defaultUserAgent: FlowUA/1.0") })
    #expect(io.outputLines.contains { $0.contains("[Cache Operations]") })
    #expect(io.outputLines.contains { $0.contains("Type '--yes' to confirm") })
    #expect(io.outputLines.contains { $0.contains("Cleared cache for alias 'MDFLOW1'.") })
    #expect(io.outputLines.contains { $0.contains("Alias state: present") })

    let info = try context.facade.cacheInfo(alias: "MDFLOW1")
    #expect(info.totalBytesOnDisk == 0)
}
