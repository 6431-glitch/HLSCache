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

final class ProxyServerRuntime: @unchecked Sendable {
#if canImport(Network)
    private var networkRuntime: AnyObject?
#endif

    func start(host: String, port: Int) throws -> URL {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw ProxyServerRuntimeError.invalidHost(host)
        }
        guard (0...65_535).contains(port) else {
            throw ProxyServerRuntimeError.invalidPort(port)
        }

#if canImport(Network)
        if #available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *) {
            if networkRuntime == nil {
                networkRuntime = NetworkProxyServerRuntime()
            }
            guard let runtime = networkRuntime as? NetworkProxyServerRuntime else {
                throw ProxyServerRuntimeError.networkStackUnavailable
            }
            return try runtime.start(host: trimmedHost, port: port)
        }
#endif

        throw ProxyServerRuntimeError.networkStackUnavailable
    }

    func stop() {
#if canImport(Network)
        if #available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *) {
            (networkRuntime as? NetworkProxyServerRuntime)?.stop()
        }
#endif
    }
}

#if canImport(Network)
@available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
private final class NetworkProxyServerRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "HLSCache.ProxyRuntime")
    private let startupTimeoutSeconds: TimeInterval = 2
    private var listener: NWListener?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private var runningBaseURL: URL?

    func start(host: String, port: Int) throws -> URL {
        if let existing = queue.sync(execute: { runningBaseURL }) {
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
            self?.queue.async { [weak self] in
                self?.handle(connection)
            }
        }

        listener.start(queue: queue)

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

        queue.sync {
            self.listener = listener
            self.runningBaseURL = startedURL
        }
        return startedURL
    }

    func stop() {
        queue.sync {
            activeConnections.values.forEach { $0.cancel() }
            activeConnections.removeAll()
            listener?.cancel()
            listener = nil
            runningBaseURL = nil
        }
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
                self.queue.async {
                    self.activeConnections.removeValue(forKey: identifier)
                }
            default:
                break
            }
        }

        connection.start(queue: queue)
        receiveAndRespond(connection, identifier: identifier)
    }

    private func receiveAndRespond(_ connection: NWConnection, identifier: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            guard let data,
                  !data.isEmpty else {
                connection.cancel()
                self.queue.async {
                    self.activeConnections.removeValue(forKey: identifier)
                }
                return
            }

            let request = String(data: data, encoding: .utf8) ?? ""
            let response = self.httpResponse(for: request)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
                self.queue.async {
                    self.activeConnections.removeValue(forKey: identifier)
                }
            })
        }
    }

    private func httpResponse(for request: String) -> Data {
        let requestLine = request.components(separatedBy: "\r\n").first ?? ""
        let components = requestLine.split(separator: " ", omittingEmptySubsequences: true)

        guard components.count >= 2 else {
            return makeHTTPResponse(status: "400 Bad Request", body: "bad request\n", includeBody: true)
        }

        let method = components[0].uppercased()
        let path = String(components[1])
        let includeBody = method != "HEAD"

        if method != "GET", method != "HEAD" {
            return makeHTTPResponse(status: "405 Method Not Allowed", body: "method not allowed\n", includeBody: includeBody)
        }

        if path == "/" || path == "/health" {
            return makeHTTPResponse(status: "200 OK", body: "ok\n", includeBody: includeBody)
        }

        return makeHTTPResponse(status: "404 Not Found", body: "not found\n", includeBody: includeBody)
    }

    private func makeHTTPResponse(status: String, body: String, includeBody: Bool) -> Data {
        let payload = includeBody ? body : ""
        let header = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Length: \(payload.utf8.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        return Data(header.utf8) + Data(payload.utf8)
    }
}

@available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
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
