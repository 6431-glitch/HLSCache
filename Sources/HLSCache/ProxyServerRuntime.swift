import Foundation

#if canImport(Network)
@preconcurrency import Network
#endif

public enum ProxyRuntimeState: String, Sendable, Equatable {
    case starting
    case running
    case stopping
    case stopped
}

public enum ProxyServerRuntimeError: Error, Equatable, Sendable {
    case invalidHost(String)
    case invalidPort(Int)
    case networkStackUnavailable
    case listenerBindFailed(host: String, port: Int, reason: String)
    case listenerStartupTimedOut(host: String, port: Int, timeoutSeconds: TimeInterval)
}

extension ProxyServerRuntimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidHost(host):
            return "Proxy runtime host is invalid: '\(host)'. Provide a non-empty host."
        case let .invalidPort(port):
            return "Proxy runtime port is invalid: \(port). Valid range is 0...65535."
        case .networkStackUnavailable:
            return "Proxy runtime is unavailable: the current platform does not provide Network.framework."
        case let .listenerBindFailed(host, port, reason):
            return "Failed to bind proxy listener at \(host):\(port). Verify host/port availability and permissions. Underlying error: \(reason)"
        case let .listenerStartupTimedOut(host, port, timeoutSeconds):
            return "Proxy listener did not reach ready state at \(host):\(port) within \(timeoutSeconds)s."
        }
    }
}

struct ProxyServerHTTPRequest: Sendable {
    let method: String
    let target: String
    let path: String
    let headers: [String: String]
}

struct ProxyServerHTTPResponse: Sendable {
    let statusCode: Int
    let reasonPhrase: String
    let headers: [String: String]
    let body: Data

    static func text(statusCode: Int, reasonPhrase: String, body: String) -> ProxyServerHTTPResponse {
        ProxyServerHTTPResponse(
            statusCode: statusCode,
            reasonPhrase: reasonPhrase,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(body.utf8)
        )
    }
}

// Wraps runtime mutation behind a private serial dispatch queue.
final class ProxyServerRuntime: @unchecked Sendable {
#if canImport(Network)
    private var networkRuntime: AnyObject?
#endif

    func start(
        host: String,
        port: Int,
        requestHandler: (@Sendable (ProxyServerHTTPRequest) async -> ProxyServerHTTPResponse)? = nil
    ) throws -> URL {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw ProxyServerRuntimeError.invalidHost(host)
        }
        guard (0...65_535).contains(port) else {
            throw ProxyServerRuntimeError.invalidPort(port)
        }

#if canImport(Network)
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            if networkRuntime == nil {
                networkRuntime = NetworkProxyServerRuntime()
            }
            guard let runtime = networkRuntime as? NetworkProxyServerRuntime else {
                throw ProxyServerRuntimeError.networkStackUnavailable
            }
            return try runBlockingRuntime {
                try await runtime.start(host: trimmedHost, port: port, requestHandler: requestHandler)
            }
        }
#endif

        throw ProxyServerRuntimeError.networkStackUnavailable
    }

    func stop() {
#if canImport(Network)
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            if let runtime = networkRuntime as? NetworkProxyServerRuntime {
                _ = try? runBlockingRuntime {
                    await runtime.stop()
                }
            }
        }
#endif
    }
}

#if canImport(Network)
@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
// Bridges async actor calls to sync APIs that must remain source-compatible.
private final class RuntimeBlockingResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<T, Error>?

    func complete(_ result: Result<T, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait() throws -> T {
        semaphore.wait()
        lock.lock()
        let captured = result
        lock.unlock()
        guard let captured else {
            fatalError("RuntimeBlockingResultBox completed without a result")
        }
        return try captured.get()
    }
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
private func runBlockingRuntime<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let box = RuntimeBlockingResultBox<T>()
    Task {
        do {
            box.complete(.success(try await operation()))
        } catch {
            box.complete(.failure(error))
        }
    }
    return try box.wait()
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
// Owns mutable listener/connection runtime state with actor isolation.
private actor NetworkProxyServerRuntime {
    private let ioQueue = DispatchQueue(label: "HLSCache.ProxyRuntime")
    private let startupTimeoutSeconds: TimeInterval = 2
    private var listener: NWListener?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private var runningBaseURL: URL?
    private var requestHandler: (@Sendable (ProxyServerHTTPRequest) async -> ProxyServerHTTPResponse)?

    func start(
        host: String,
        port: Int,
        requestHandler: (@Sendable (ProxyServerHTTPRequest) async -> ProxyServerHTTPResponse)?
    ) throws -> URL {
        if let existing = runningBaseURL {
            return existing
        }

        let nwPort = try makeNWPort(from: port)

        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: nwPort)
        } catch {
            throw ProxyServerRuntimeError.listenerBindFailed(
                host: host,
                port: port,
                reason: error.localizedDescription
            )
        }

        let startup = StartupBox()
        let readySignal = DispatchSemaphore(value: 0)

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let boundPort = listener.port.map { Int($0.rawValue) } ?? port
                startup.setURL(URL(string: "http://\(host):\(boundPort)"))
                readySignal.signal()
            case let .failed(error):
                startup.setError(
                    ProxyServerRuntimeError.listenerBindFailed(
                        host: host,
                        port: port,
                        reason: error.localizedDescription
                    )
                )
                readySignal.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { [weak self] in
                await self?.handle(connection)
            }
        }

        listener.start(queue: ioQueue)

        let didStart = readySignal.wait(timeout: .now() + startupTimeoutSeconds) == .success
        if !didStart {
            listener.cancel()
            throw ProxyServerRuntimeError.listenerStartupTimedOut(
                host: host,
                port: port,
                timeoutSeconds: startupTimeoutSeconds
            )
        }

        if let startupError = startup.error {
            listener.cancel()
            throw startupError
        }

        guard let startedURL = startup.url else {
            listener.cancel()
            throw ProxyServerRuntimeError.listenerStartupTimedOut(
                host: host,
                port: port,
                timeoutSeconds: startupTimeoutSeconds
            )
        }

        self.listener = listener
        self.runningBaseURL = startedURL
        self.requestHandler = requestHandler
        return startedURL
    }

    func stop() {
        activeConnections.values.forEach { $0.cancel() }
        activeConnections.removeAll()
        listener?.cancel()
        listener = nil
        runningBaseURL = nil
        requestHandler = nil
    }

    private func makeNWPort(from rawPort: Int) throws -> NWEndpoint.Port {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(rawPort)) else {
            throw ProxyServerRuntimeError.invalidPort(rawPort)
        }
        return nwPort
    }

    private func handle(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        activeConnections[identifier] = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else {
                return
            }
            switch state {
            case .failed, .cancelled:
                Task {
                    await self.removeConnection(identifier)
                }
            default:
                break
            }
        }

        connection.start(queue: ioQueue)
        receiveAndRespond(connection, identifier: identifier, accumulated: Data())
    }

    private func receiveAndRespond(
        _ connection: NWConnection,
        identifier: ObjectIdentifier,
        accumulated: Data
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            Task {
                await self.processReceive(
                    data: data,
                    connection: connection,
                    identifier: identifier,
                    accumulated: accumulated
                )
            }
        }
    }

    private func processReceive(
        data: Data?,
        connection: NWConnection,
        identifier: ObjectIdentifier,
        accumulated: Data
    ) async {
        var buffer = accumulated
        if let data, !data.isEmpty {
            buffer.append(data)
        }

        guard !buffer.isEmpty else {
            connection.cancel()
            activeConnections.removeValue(forKey: identifier)
            return
        }

        guard requestHeadersComplete(in: buffer) else {
            receiveAndRespond(connection, identifier: identifier, accumulated: buffer)
            return
        }

        let responseData = await httpResponse(for: buffer)
        let runtime = self
        ioQueue.async {
            connection.send(content: responseData, completion: .contentProcessed { _ in
                connection.cancel()
                Task {
                    await runtime.removeConnection(identifier)
                }
            })
        }
    }

    private func removeConnection(_ identifier: ObjectIdentifier) {
        activeConnections.removeValue(forKey: identifier)
    }

    private func requestHeadersComplete(in data: Data) -> Bool {
        data.range(of: Data("\r\n\r\n".utf8)) != nil
    }

    private func parseHTTPRequest(_ requestData: Data) -> ProxyServerHTTPRequest? {
        guard let request = String(data: requestData, encoding: .utf8) else {
            return nil
        }
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }
        let components = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count >= 2 else {
            return nil
        }

        let method = String(components[0]).uppercased()
        let target = String(components[1])
        let path = pathFromRequestTarget(target)

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty {
                break
            }
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        return ProxyServerHTTPRequest(method: method, target: target, path: path, headers: headers)
    }

    private func pathFromRequestTarget(_ target: String) -> String {
        let rawPath = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        if rawPath.hasPrefix("/") {
            return rawPath
        }
        return "/" + rawPath
    }

    private func httpResponse(for requestData: Data) async -> Data {
        guard let request = parseHTTPRequest(requestData) else {
            return makeHTTPResponse(
                from: .text(statusCode: 400, reasonPhrase: "Bad Request", body: "bad request\n"),
                includeBody: true
            )
        }

        let includeBody = request.method != "HEAD"
        if request.method != "GET", request.method != "HEAD" {
            return makeHTTPResponse(
                from: .text(statusCode: 405, reasonPhrase: "Method Not Allowed", body: "method not allowed\n"),
                includeBody: includeBody
            )
        }

        if request.path == "/" || request.path == "/health" {
            return makeHTTPResponse(
                from: .text(statusCode: 200, reasonPhrase: "OK", body: "ok\n"),
                includeBody: includeBody
            )
        }

        if let requestHandler {
            let response = await requestHandler(request)
            return makeHTTPResponse(from: response, includeBody: includeBody)
        }

        return makeHTTPResponse(
            from: .text(statusCode: 404, reasonPhrase: "Not Found", body: "not found\n"),
            includeBody: includeBody
        )
    }

    private func makeHTTPResponse(from response: ProxyServerHTTPResponse, includeBody: Bool) -> Data {
        let payload = includeBody ? response.body : Data()
        var headers = response.headers
        if headers["Content-Length"] == nil {
            headers["Content-Length"] = String(response.body.count)
        }
        headers["Connection"] = "close"

        var lines = ["HTTP/1.1 \(response.statusCode) \(response.reasonPhrase)"]
        for key in headers.keys.sorted() {
            if let value = headers[key] {
                lines.append("\(key): \(value)")
            }
        }
        lines.append("")
        lines.append("")
        let headerData = Data(lines.joined(separator: "\r\n").utf8)
        return headerData + payload
    }
}

@available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
// Uses an NSLock to synchronize startup result publication across threads.
private final class StartupBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedURL: URL?
    private var storedError: ProxyServerRuntimeError?

    var url: URL? {
        lock.lock()
        defer { lock.unlock() }
        return storedURL
    }

    var error: ProxyServerRuntimeError? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func setURL(_ url: URL?) {
        lock.lock()
        storedURL = url
        lock.unlock()
    }

    func setError(_ error: ProxyServerRuntimeError) {
        lock.lock()
        storedError = error
        lock.unlock()
    }
}
#endif
