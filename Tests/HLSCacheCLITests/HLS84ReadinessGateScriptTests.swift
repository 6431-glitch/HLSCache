import Foundation
import Testing

private struct GateScriptFixture: Encodable {
    struct IssueStatus: Encodable {
        let statusName: String
        let statusCategory: String
    }

    let statuses: [String: IssueStatus]
}

private struct GateScriptReport: Decodable {
    let schemaVersion: String
    let generatedAt: String
    let mode: String
    let passed: Bool
    let dependencies: [Dependency]

    struct Dependency: Decodable {
        let key: String
        let statusName: String
        let statusCategory: String
        let expected: String
        let passed: Bool
        let error: String?
    }
}

private struct GateScriptRunResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private func readinessScriptRepositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // HLSCacheCLITests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
}

private func runReadinessGateScript(arguments: [String]) throws -> GateScriptRunResult {
    let repositoryRoot = readinessScriptRepositoryRoot()
    let scriptURL = repositoryRoot.appendingPathComponent("Scripts/check_hls84_readiness_gate.swift")

    let process = Process()
    process.currentDirectoryURL = repositoryRoot
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift", scriptURL.path] + arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    process.waitUntilExit()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
    return GateScriptRunResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
}

private func writeReadinessFixture(_ fixture: GateScriptFixture) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-readiness-gate-fixtures")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let fixtureURL = directory.appendingPathComponent("fixture.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(fixture)
    try data.write(to: fixtureURL)
    return fixtureURL
}

private func parseGateReport(from output: String) throws -> GateScriptReport {
    try JSONDecoder().decode(GateScriptReport.self, from: Data(output.utf8))
}

@Test func readinessGate_fixtureMode_textOutput_contractIsDeterministic() throws {
    let fixtureURL = try writeReadinessFixture(
        GateScriptFixture(
            statuses: [
                "HLS-39": .init(statusName: "Done", statusCategory: "Done"),
                "HLS-38": .init(statusName: "Done", statusCategory: "Done"),
                "HLS-37": .init(statusName: "Done", statusCategory: "Done"),
                "HLS-35": .init(statusName: "Done", statusCategory: "Done"),
                "HLS-34": .init(statusName: "Done", statusCategory: "Done"),
                "HLS-36": .init(statusName: "In Progress", statusCategory: "In Progress")
            ]
        )
    )
    defer { try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent()) }

    let result = try runReadinessGateScript(
        arguments: [
            "--mode", "minimum",
            "--format", "text",
            "--fixture-file", fixtureURL.path
        ]
    )

    #expect(result.status == 0)
    #expect(result.stderr.isEmpty)
    #expect(result.stdout.contains("HLS-84 readiness gate snapshot @"))
    #expect(result.stdout.contains("Mode: minimum"))
    #expect(
        result.stdout.contains(
            "- HLS-36 | status=In Progress | category=In Progress | expected=In Progress or Done (status category) | result=PASS"
        )
    )
    #expect(result.stdout.contains("Gate result: PASS"))
}

@Test func readinessGate_fixtureMode_jsonOutput_contractIsDeterministic() throws {
    let fixtureURL = try writeReadinessFixture(
        GateScriptFixture(
            statuses: [
                "HLS-39": .init(statusName: "Done", statusCategory: "Done"),
                "HLS-38": .init(statusName: "Done", statusCategory: "Done"),
                "HLS-37": .init(statusName: "Done", statusCategory: "Done"),
                "HLS-35": .init(statusName: "In Progress", statusCategory: "In Progress"),
                "HLS-34": .init(statusName: "Done", statusCategory: "Done"),
                "HLS-36": .init(statusName: "Done", statusCategory: "Done")
            ]
        )
    )
    defer { try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent()) }

    let result = try runReadinessGateScript(
        arguments: [
            "--mode", "minimum",
            "--format", "json",
            "--fixture-file", fixtureURL.path
        ]
    )

    #expect(result.status == 1)
    #expect(result.stderr.isEmpty)

    let report = try parseGateReport(from: result.stdout)
    #expect(report.schemaVersion == "1")
    #expect(report.mode == "minimum")
    #expect(report.passed == false)
    #expect(report.generatedAt.contains("T"))
    #expect(report.dependencies.count == 6)

    let failingDependency = report.dependencies.first { $0.key == "HLS-35" }
    #expect(failingDependency?.statusCategory == "In Progress")
    #expect(failingDependency?.expected == "Done (status category)")
    #expect(failingDependency?.passed == false)
    #expect(failingDependency?.error == nil)
}

@Test func readinessGate_fixtureMode_chainedLifecycleContinuityScenario_transitionsExpectedStates() throws {
    let fixtureInProgressURL = try writeReadinessFixture(
        GateScriptFixture(
            statuses: [
                "HLS-39": .init(statusName: "Done", statusCategory: "Done"),
                "HLS-38": .init(statusName: "Done", statusCategory: "Done"),
                "HLS-37": .init(statusName: "Done", statusCategory: "Done"),
                "HLS-35": .init(statusName: "Done", statusCategory: "Done"),
                "HLS-34": .init(statusName: "Done", statusCategory: "Done"),
                "HLS-36": .init(statusName: "In Progress", statusCategory: "In Progress")
            ]
        )
    )
    defer { try? FileManager.default.removeItem(at: fixtureInProgressURL.deletingLastPathComponent()) }

    let fixtureDoneURL = try writeReadinessFixture(
        GateScriptFixture(
            statuses: [
                "HLS-39": .init(statusName: "Done", statusCategory: "Done"),
                "HLS-38": .init(statusName: "Done", statusCategory: "Done"),
                "HLS-37": .init(statusName: "Done", statusCategory: "Done"),
                "HLS-35": .init(statusName: "Done", statusCategory: "Done"),
                "HLS-34": .init(statusName: "Done", statusCategory: "Done"),
                "HLS-36": .init(statusName: "Done", statusCategory: "Done")
            ]
        )
    )
    defer { try? FileManager.default.removeItem(at: fixtureDoneURL.deletingLastPathComponent()) }

    let minimumRun = try runReadinessGateScript(
        arguments: ["--mode", "minimum", "--format", "json", "--fixture-file", fixtureInProgressURL.path]
    )
    #expect(minimumRun.status == 0)
    let minimumReport = try parseGateReport(from: minimumRun.stdout)
    #expect(minimumReport.passed == true)

    let finalBeforeDoneRun = try runReadinessGateScript(
        arguments: ["--mode", "final", "--format", "json", "--fixture-file", fixtureInProgressURL.path]
    )
    #expect(finalBeforeDoneRun.status == 1)
    let finalBeforeDoneReport = try parseGateReport(from: finalBeforeDoneRun.stdout)
    #expect(finalBeforeDoneReport.passed == false)
    #expect(finalBeforeDoneReport.dependencies.first { $0.key == "HLS-36" }?.passed == false)

    let finalDoneRun = try runReadinessGateScript(
        arguments: ["--mode", "final", "--format", "json", "--fixture-file", fixtureDoneURL.path]
    )
    #expect(finalDoneRun.status == 0)
    let finalDoneReport = try parseGateReport(from: finalDoneRun.stdout)
    #expect(finalDoneReport.passed == true)
    #expect(finalDoneReport.dependencies.first { $0.key == "HLS-36" }?.passed == true)
}
