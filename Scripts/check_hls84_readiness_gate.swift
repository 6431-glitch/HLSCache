#!/usr/bin/env swift

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum GateMode: String {
    case minimum
    case final
}

enum GateOutputFormat: String {
    case text
    case json
}

struct Dependency {
    let key: String
    let name: String
}

struct DependencySnapshot: Codable {
    let key: String
    let name: String
    let statusName: String
    let statusCategory: String
    let expected: String
    let passed: Bool
    let error: String?
}

struct GateReport: Codable {
    let schemaVersion: String
    let generatedAt: String
    let mode: String
    let passed: Bool
    let dependencies: [DependencySnapshot]
}

struct FixtureIssueStatus: Codable {
    let statusName: String
    let statusCategory: String
}

struct GateFixture: Codable {
    let statuses: [String: FixtureIssueStatus]
}

enum GateScriptError: LocalizedError {
    case invalidArguments(String)
    case missingEnvironment(String)
    case invalidBaseURL(String)
    case requestFailed(String)
    case responseDecodeFailed(String)
    case fixtureLoadFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(message):
            return "Invalid arguments: \(message)"
        case let .missingEnvironment(message):
            return "Missing environment: \(message)"
        case let .invalidBaseURL(value):
            return "Invalid JIRA_BASE_URL: '\(value)'"
        case let .requestFailed(message):
            return "Jira request failed: \(message)"
        case let .responseDecodeFailed(message):
            return "Jira response decode failed: \(message)"
        case let .fixtureLoadFailed(message):
            return "Fixture load failed: \(message)"
        }
    }
}

struct ScriptConfiguration {
    let mode: GateMode
    let format: GateOutputFormat
    let timeoutSeconds: TimeInterval
    let fixtureFilePath: String?
}

private let dependencies: [Dependency] = [
    Dependency(key: "HLS-39", name: "HLSC-CORE — CoreCache Foundation"),
    Dependency(key: "HLS-38", name: "HLSC-PROXY — SwiftNIO Proxy Server"),
    Dependency(key: "HLS-37", name: "HLSC-HLS — HLS Playback Support"),
    Dependency(key: "HLS-35", name: "HLSC-PLUGIN — Transform Pipeline"),
    Dependency(key: "HLS-34", name: "HLSC-HARDEN — Stability & Observability"),
    Dependency(key: "HLS-36", name: "HLSC-DOWNLOAD — Background Offline HLS"),
]

private let usage = """
Usage:
  swift Scripts/check_hls84_readiness_gate.swift [--mode <minimum|final>] [--format <text|json>] [--timeout-seconds <seconds>] [--fixture-file <path>]

Environment:
  JIRA_BASE_URL     Jira base URL (for example: https://your-org.atlassian.net)
  JIRA_USER_EMAIL   Jira user email for API auth
  JIRA_API_TOKEN    Jira API token for API auth
"""

private func parseConfiguration(arguments: [String]) throws -> ScriptConfiguration {
    var mode: GateMode = .minimum
    var format: GateOutputFormat = .text
    var timeoutSeconds: TimeInterval = 20
    var fixtureFilePath: String?

    var index = 0
    while index < arguments.count {
        let option = arguments[index]
        switch option {
        case "--mode":
            index += 1
            guard index < arguments.count, let parsed = GateMode(rawValue: arguments[index]) else {
                throw GateScriptError.invalidArguments("--mode expects minimum or final")
            }
            mode = parsed
        case "--format":
            index += 1
            guard index < arguments.count, let parsed = GateOutputFormat(rawValue: arguments[index]) else {
                throw GateScriptError.invalidArguments("--format expects text or json")
            }
            format = parsed
        case "--timeout-seconds":
            index += 1
            guard index < arguments.count, let parsed = Double(arguments[index]), parsed > 0 else {
                throw GateScriptError.invalidArguments("--timeout-seconds expects a positive number")
            }
            timeoutSeconds = parsed
        case "--fixture-file":
            index += 1
            guard index < arguments.count, !arguments[index].isEmpty else {
                throw GateScriptError.invalidArguments("--fixture-file expects a path")
            }
            fixtureFilePath = arguments[index]
        case "--help", "-h":
            print(usage)
            exit(EXIT_SUCCESS)
        default:
            throw GateScriptError.invalidArguments("unknown option '\(option)'")
        }
        index += 1
    }

    return ScriptConfiguration(
        mode: mode,
        format: format,
        timeoutSeconds: timeoutSeconds,
        fixtureFilePath: fixtureFilePath
    )
}

private func requiredEnvironmentValue(_ key: String) throws -> String {
    guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
        throw GateScriptError.missingEnvironment("\(key) is required")
    }
    return value
}

private func expectation(for key: String, mode: GateMode) -> (description: String, pass: (String) -> Bool) {
    if key == "HLS-36" {
        switch mode {
        case .minimum:
            return ("In Progress or Done (status category)", { category in
                category == "In Progress" || category == "Done"
            })
        case .final:
            return ("Done (status category)", { category in
                category == "Done"
            })
        }
    }

    return ("Done (status category)", { category in
        category == "Done"
    })
}

private func isoTimestampNow() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: Date())
}

private func performRequest(_ request: URLRequest, timeoutSeconds: TimeInterval) throws -> (Data, HTTPURLResponse) {
    let semaphore = DispatchSemaphore(value: 0)
    var capturedData: Data?
    var capturedResponse: URLResponse?
    var capturedError: Error?

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        capturedData = data
        capturedResponse = response
        capturedError = error
        semaphore.signal()
    }
    task.resume()

    let timeoutResult = semaphore.wait(timeout: .now() + timeoutSeconds)
    if timeoutResult == .timedOut {
        task.cancel()
        throw GateScriptError.requestFailed("request timed out after \(Int(timeoutSeconds))s")
    }

    if let error = capturedError {
        throw GateScriptError.requestFailed(error.localizedDescription)
    }
    guard let response = capturedResponse as? HTTPURLResponse else {
        throw GateScriptError.requestFailed("missing HTTP response")
    }
    guard let data = capturedData else {
        throw GateScriptError.requestFailed("missing response body")
    }
    return (data, response)
}

private func loadFixtureStatuses(path: String) throws -> [String: FixtureIssueStatus] {
    let fileURL = URL(fileURLWithPath: path)
    let data: Data
    do {
        data = try Data(contentsOf: fileURL)
    } catch {
        throw GateScriptError.fixtureLoadFailed("unable to read '\(path)': \(error.localizedDescription)")
    }

    do {
        let fixture = try JSONDecoder().decode(GateFixture.self, from: data)
        return fixture.statuses
    } catch {
        throw GateScriptError.fixtureLoadFailed("unable to decode '\(path)': \(error.localizedDescription)")
    }
}

private func snapshotFromFixture(
    dependency: Dependency,
    mode: GateMode,
    statuses: [String: FixtureIssueStatus]
) throws -> DependencySnapshot {
    guard let status = statuses[dependency.key] else {
        throw GateScriptError.fixtureLoadFailed("missing status fixture for \(dependency.key)")
    }
    let (expected, pass) = expectation(for: dependency.key, mode: mode)
    return DependencySnapshot(
        key: dependency.key,
        name: dependency.name,
        statusName: status.statusName,
        statusCategory: status.statusCategory,
        expected: expected,
        passed: pass(status.statusCategory),
        error: nil
    )
}

private func fetchDependencySnapshot(
    baseURL: URL,
    userEmail: String,
    apiToken: String,
    dependency: Dependency,
    mode: GateMode,
    timeoutSeconds: TimeInterval
) throws -> DependencySnapshot {
    var components = URLComponents(
        url: baseURL.appendingPathComponent("/rest/api/3/issue/\(dependency.key)"),
        resolvingAgainstBaseURL: false
    )
    components?.queryItems = [URLQueryItem(name: "fields", value: "summary,status")]
    guard let url = components?.url else {
        throw GateScriptError.invalidBaseURL(baseURL.absoluteString)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = timeoutSeconds
    let credential = "\(userEmail):\(apiToken)"
    let authValue = Data(credential.utf8).base64EncodedString()
    request.setValue("Basic \(authValue)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try performRequest(request, timeoutSeconds: timeoutSeconds)
    guard (200...299).contains(response.statusCode) else {
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        throw GateScriptError.requestFailed("\(dependency.key) returned HTTP \(response.statusCode): \(body)")
    }

    let object: Any
    do {
        object = try JSONSerialization.jsonObject(with: data)
    } catch {
        throw GateScriptError.responseDecodeFailed("\(dependency.key): \(error.localizedDescription)")
    }

    guard let root = object as? [String: Any],
          let fields = root["fields"] as? [String: Any],
          let status = fields["status"] as? [String: Any] else {
        throw GateScriptError.responseDecodeFailed("\(dependency.key): missing fields.status")
    }

    let statusName = (status["name"] as? String) ?? "unknown"
    let statusCategory = ((status["statusCategory"] as? [String: Any])?["name"] as? String) ?? "unknown"
    let (expected, pass) = expectation(for: dependency.key, mode: mode)

    return DependencySnapshot(
        key: dependency.key,
        name: dependency.name,
        statusName: statusName,
        statusCategory: statusCategory,
        expected: expected,
        passed: pass(statusCategory),
        error: nil
    )
}

private func makeErrorSnapshot(
    dependency: Dependency,
    mode: GateMode,
    error: Error
) -> DependencySnapshot {
    let (expected, _) = expectation(for: dependency.key, mode: mode)
    return DependencySnapshot(
        key: dependency.key,
        name: dependency.name,
        statusName: "unknown",
        statusCategory: "unknown",
        expected: expected,
        passed: false,
        error: error.localizedDescription
    )
}

private func emitText(report: GateReport) {
    print("HLS-84 readiness gate snapshot @ \(report.generatedAt)")
    print("Mode: \(report.mode)")
    for dependency in report.dependencies {
        if let error = dependency.error {
            print("- \(dependency.key) | expected=\(dependency.expected) | result=FAIL | error=\(error)")
            continue
        }
        let result = dependency.passed ? "PASS" : "FAIL"
        print(
            "- \(dependency.key) | status=\(dependency.statusName) | category=\(dependency.statusCategory) | expected=\(dependency.expected) | result=\(result)"
        )
    }
    print("Gate result: \(report.passed ? "PASS" : "FAIL")")
}

private func emitJSON(report: GateReport) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    if let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) {
        print(text)
        return
    }

    // Fallback to text if JSON encoding unexpectedly fails.
    emitText(report: report)
}

do {
    let config = try parseConfiguration(arguments: Array(CommandLine.arguments.dropFirst()))
    let fixtureStatuses = try config.fixtureFilePath.map(loadFixtureStatuses(path:))

    let baseURL: URL?
    let userEmail: String?
    let apiToken: String?
    if fixtureStatuses == nil {
        let baseURLRaw = try requiredEnvironmentValue("JIRA_BASE_URL")
        userEmail = try requiredEnvironmentValue("JIRA_USER_EMAIL")
        apiToken = try requiredEnvironmentValue("JIRA_API_TOKEN")
        guard let parsedBaseURL = URL(string: baseURLRaw) else {
            throw GateScriptError.invalidBaseURL(baseURLRaw)
        }
        baseURL = parsedBaseURL
    } else {
        baseURL = nil
        userEmail = nil
        apiToken = nil
    }

    var snapshots: [DependencySnapshot] = []
    snapshots.reserveCapacity(dependencies.count)

    for dependency in dependencies {
        do {
            let snapshot: DependencySnapshot
            if let fixtureStatuses {
                snapshot = try snapshotFromFixture(
                    dependency: dependency,
                    mode: config.mode,
                    statuses: fixtureStatuses
                )
            } else {
                guard let baseURL, let userEmail, let apiToken else {
                    throw GateScriptError.missingEnvironment("Jira credentials are required when --fixture-file is not provided")
                }
                snapshot = try fetchDependencySnapshot(
                    baseURL: baseURL,
                    userEmail: userEmail,
                    apiToken: apiToken,
                    dependency: dependency,
                    mode: config.mode,
                    timeoutSeconds: config.timeoutSeconds
                )
            }
            snapshots.append(snapshot)
        } catch {
            snapshots.append(makeErrorSnapshot(dependency: dependency, mode: config.mode, error: error))
        }
    }

    let passed = snapshots.allSatisfy(\.passed)
    let report = GateReport(
        schemaVersion: "1",
        generatedAt: isoTimestampNow(),
        mode: config.mode.rawValue,
        passed: passed,
        dependencies: snapshots
    )

    switch config.format {
    case .text:
        emitText(report: report)
    case .json:
        emitJSON(report: report)
    }

    exit(passed ? EXIT_SUCCESS : EXIT_FAILURE)
} catch {
    fputs("\(error.localizedDescription)\n\n\(usage)\n", stderr)
    exit(2)
}
