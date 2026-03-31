import CoreCache
import Foundation
import Get
import Pulse

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum NetworkClientError: Error, Equatable, Sendable {
    case nonHTTPResponse
    case unexpectedHTTPStatusCode(expected: Int, actual: Int)
    case invalidRangeResponseLength(expected: Int64, actual: Int)
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public protocol NetworkClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public struct URLSessionNetworkClient: NetworkClient, @unchecked Sendable {
    private let session: URLSession
    private let transport: @Sendable (URLSession, URLRequest) async throws -> (Data, URLResponse)

    public init(session: URLSession = .shared) {
        self.session = session
        self.transport = URLSessionNetworkClient.defaultTransport
    }

    init(
        session: URLSession,
        transport: @escaping @Sendable (URLSession, URLRequest) async throws -> (Data, URLResponse)
    ) {
        self.session = session
        self.transport = transport
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await transport(session, request)
    }

    private static func defaultTransport(
        session: URLSession,
        request: URLRequest
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data, let response else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }

                continuation.resume(returning: (data, response))
            }
            task.resume()
        }
    }
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public struct GetNetworkClient: NetworkClient, @unchecked Sendable {
    private let client: APIClient

    public init(client: APIClient) {
        self.client = client
    }

    public init(
        sessionConfiguration: URLSessionConfiguration = .default,
        sessionDelegate: URLSessionDelegate? = nil,
        networkLogger: NetworkLogger = .shared
    ) {
        let copiedConfiguration = (sessionConfiguration.copy() as? URLSessionConfiguration) ?? sessionConfiguration
        let proxyDelegate = URLSessionProxyDelegate(logger: networkLogger, delegate: sessionDelegate)
        self.client = APIClient(baseURL: nil) {
            $0.sessionConfiguration = copiedConfiguration
            $0.sessionDelegate = proxyDelegate
        }
    }

    public static func pulseEnabled(
        sessionConfiguration: URLSessionConfiguration = .default,
        sessionDelegate: URLSessionDelegate? = nil
    ) -> GetNetworkClient {
        let logger = NetworkLogger(store: .shared)
        NetworkLogger.shared = logger
        return GetNetworkClient(
            sessionConfiguration: sessionConfiguration,
            sessionDelegate: sessionDelegate,
            networkLogger: logger
        )
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }

        let method = HTTPMethod(rawValue: request.httpMethod ?? HTTPMethod.get.rawValue)
        let getRequest = Request<Data>(
            url: url,
            method: method,
            headers: request.allHTTPHeaderFields
        )

        let response = try await client.data(for: getRequest) { mutableRequest in
            mutableRequest.httpBody = request.httpBody
            mutableRequest.httpBodyStream = request.httpBodyStream
            mutableRequest.cachePolicy = request.cachePolicy
            mutableRequest.timeoutInterval = request.timeoutInterval
        }

        return (response.value, response.response)
    }
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public struct ClosureNetworkClient: NetworkClient {
    public typealias Handler = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let handler: Handler

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await handler(request)
    }
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public extension NetworkClient {
    func data(from url: URL, headers: [String: String] = [:]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return try await data(for: request)
    }

    func data(
        from url: URL,
        byteRange: ByteRange,
        headers: [String: String] = [:]
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "bytes=\(byteRange.start)-\(byteRange.endExclusive - 1)",
            forHTTPHeaderField: "Range"
        )
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkClientError.nonHTTPResponse
        }
        guard httpResponse.statusCode == 206 else {
            throw NetworkClientError.unexpectedHTTPStatusCode(expected: 206, actual: httpResponse.statusCode)
        }
        guard data.count == Int(byteRange.length) else {
            throw NetworkClientError.invalidRangeResponseLength(expected: byteRange.length, actual: data.count)
        }
        return data
    }
}
