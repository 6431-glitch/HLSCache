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

enum ProxyServerHTTPBodyStreamError: Error, Sendable {
    case fallbackResponse(statusCode: Int, reasonPhrase: String, body: String)
    case streamingFailed(reason: String)
}

enum ProxyServerHTTPBody: Sendable {
    case data(Data)
    case stream(
        @Sendable (_ emitChunk: @escaping (Data) async throws -> Void) async throws -> Void
    )
}

struct ProxyServerHTTPResponse: Sendable {
    let statusCode: Int
    let reasonPhrase: String
    let headers: [String: String]
    let body: ProxyServerHTTPBody

    init(statusCode: Int, reasonPhrase: String, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
        self.body = .data(body)
    }

    init(
        statusCode: Int,
        reasonPhrase: String,
        headers: [String: String],
        bodyStream: @escaping @Sendable (_ emitChunk: @escaping (Data) async throws -> Void) async throws -> Void
    ) {
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
        self.body = .stream(bodyStream)
    }

    static func text(statusCode: Int, reasonPhrase: String, body: String) -> ProxyServerHTTPResponse {
        ProxyServerHTTPResponse(
            statusCode: statusCode,
            reasonPhrase: reasonPhrase,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(body.utf8)
        )
    }
}

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
            return try runtime.start(host: trimmedHost, port: port, requestHandler: requestHandler)
        }
#endif

        throw ProxyServerRuntimeError.networkStackUnavailable
    }

    func stop() {
#if canImport(Network)
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            (networkRuntime as? NetworkProxyServerRuntime)?.stop()
        }
#endif
    }
}

#if canImport(Network)
@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
private final class NetworkProxyServerRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "HLSCache.ProxyRuntime")
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
            self.requestHandler = requestHandler
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
            requestHandler = nil
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

            var buffer = accumulated
            if let data, !data.isEmpty {
                buffer.append(data)
            }

            guard !buffer.isEmpty else {
                connection.cancel()
                self.queue.async {
                    self.activeConnections.removeValue(forKey: identifier)
                }
                return
            }

            guard self.requestHeadersComplete(in: buffer) else {
                self.receiveAndRespond(connection, identifier: identifier, accumulated: buffer)
                return
            }

            Task { [weak self] in
                guard let self else {
                    connection.cancel()
                    return
                }
                let preparedResponse = await self.httpResponse(for: buffer)
                await self.send(preparedResponse, over: connection)
                connection.cancel()
                self.queue.async {
                    self.activeConnections.removeValue(forKey: identifier)
                }
            }
        }
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

    private func httpResponse(for requestData: Data) async -> (response: ProxyServerHTTPResponse, includeBody: Bool) {
        guard let request = parseHTTPRequest(requestData) else {
            return (
                .text(statusCode: 400, reasonPhrase: "Bad Request", body: "bad request\n"),
                true
            )
        }

        let includeBody = request.method != "HEAD"
        if request.method != "GET", request.method != "HEAD" {
            return (
                .text(statusCode: 405, reasonPhrase: "Method Not Allowed", body: "method not allowed\n"),
                includeBody
            )
        }

        if request.path == "/" || request.path == "/health" {
            return (
                .text(statusCode: 200, reasonPhrase: "OK", body: "ok\n"),
                includeBody
            )
        }

        if let requestHandler {
            let response = await requestHandler(request)
            return (response, includeBody)
        }

        return (
            .text(statusCode: 404, reasonPhrase: "Not Found", body: "not found\n"),
            includeBody
        )
    }

    private func send(
        _ preparedResponse: (response: ProxyServerHTTPResponse, includeBody: Bool),
        over connection: NWConnection
    ) async {
        let response = preparedResponse.response
        let includeBody = preparedResponse.includeBody

        switch response.body {
        case let .data(fullBody):
            let payload = includeBody ? fullBody : Data()
            let bodyLengthHint = fullBody.count
            let responseData = makeHTTPResponse(
                statusCode: response.statusCode,
                reasonPhrase: response.reasonPhrase,
                headers: response.headers,
                payload: payload,
                bodyLengthHint: bodyLengthHint
            )
            _ = try? await sendData(responseData, over: connection)

        case let .stream(streamBody):
            guard includeBody else {
                let headersOnly = makeHTTPResponse(
                    statusCode: response.statusCode,
                    reasonPhrase: response.reasonPhrase,
                    headers: response.headers,
                    payload: Data(),
                    bodyLengthHint: nil
                )
                _ = try? await sendData(headersOnly, over: connection)
                return
            }

            let headerData = makeHTTPHeaders(
                statusCode: response.statusCode,
                reasonPhrase: response.reasonPhrase,
                headers: response.headers,
                bodyLengthHint: nil
            )

            var didSendHeaders = false
            do {
                try await streamBody { [weak self] chunk in
                    guard let self else {
                        throw ProxyServerHTTPBodyStreamError.streamingFailed(reason: "runtime deallocated")
                    }
                    if !didSendHeaders {
                        try await self.sendData(headerData, over: connection)
                        didSendHeaders = true
                    }
                    if !chunk.isEmpty {
                        try await self.sendData(chunk, over: connection)
                    }
                }

                if !didSendHeaders {
                    _ = try? await sendData(headerData, over: connection)
                }
            } catch let error as ProxyServerHTTPBodyStreamError {
                guard !didSendHeaders, let fallback = fallbackResponse(for: error) else {
                    return
                }
                let fallbackData = makeHTTPResponse(
                    statusCode: fallback.statusCode,
                    reasonPhrase: fallback.reasonPhrase,
                    headers: fallback.headers,
                    payload: fallback.bodyData,
                    bodyLengthHint: fallback.bodyData.count
                )
                _ = try? await sendData(fallbackData, over: connection)
            } catch {
                return
            }
        }
    }

    private func sendData(_ data: Data, over connection: NWConnection) async throws {
        guard !data.isEmpty else {
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                })
            }
        }
    }

    private struct FallbackHTTPResponse {
        let statusCode: Int
        let reasonPhrase: String
        let headers: [String: String]
        let bodyData: Data
    }

    private func fallbackResponse(for error: ProxyServerHTTPBodyStreamError) -> FallbackHTTPResponse? {
        switch error {
        case let .fallbackResponse(statusCode, reasonPhrase, body):
            return FallbackHTTPResponse(
                statusCode: statusCode,
                reasonPhrase: reasonPhrase,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                bodyData: Data(body.utf8)
            )
        case .streamingFailed:
            return nil
        }
    }

    private func makeHTTPResponse(
        statusCode: Int,
        reasonPhrase: String,
        headers: [String: String],
        payload: Data,
        bodyLengthHint: Int?
    ) -> Data {
        let headerData = makeHTTPHeaders(
            statusCode: statusCode,
            reasonPhrase: reasonPhrase,
            headers: headers,
            bodyLengthHint: bodyLengthHint
        )
        return headerData + payload
    }

    private func makeHTTPHeaders(
        statusCode: Int,
        reasonPhrase: String,
        headers headerFields: [String: String],
        bodyLengthHint: Int?
    ) -> Data {
        var headers = headerFields
        if headers["Content-Length"] == nil, let bodyLengthHint {
            headers["Content-Length"] = String(bodyLengthHint)
        }
        headers["Connection"] = "close"

        var lines = ["HTTP/1.1 \(statusCode) \(reasonPhrase)"]
        for key in headers.keys.sorted() {
            if let value = headers[key] {
                lines.append("\(key): \(value)")
            }
        }
        lines.append("")
        lines.append("")
        let headerData = Data(lines.joined(separator: "\r\n").utf8)
        return headerData
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
