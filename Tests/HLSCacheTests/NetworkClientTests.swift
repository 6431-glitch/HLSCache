import CoreCache
import Foundation
import Testing
@testable import HLSCache

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
private actor RequestRecorder {
    private var latestRequest: URLRequest?

    func record(_ request: URLRequest) {
        latestRequest = request
    }

    func latest() -> URLRequest? {
        latestRequest
    }
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
@Test func networkClient_rangeRequest_setsRangeHeaderAndReturnsExpectedBytes() async throws {
    let recorder = RequestRecorder()
    let targetURL = try #require(URL(string: "https://cdn.example.com/video.ts"))
    let requestedRange = try #require(ByteRange(start: 64, endExclusive: 80))

    let client = ClosureNetworkClient { request in
        await recorder.record(request)
        let response = try #require(
            HTTPURLResponse(
                url: targetURL,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes 64-79/4096"]
            )
        )
        return (Data(repeating: 0xAB, count: 16), response)
    }

    let body = try await client.data(
        from: targetURL,
        byteRange: requestedRange,
        headers: ["User-Agent": "HLSCacheTests/1.0"]
    )

    let captured = try #require(await recorder.latest())
    #expect(captured.value(forHTTPHeaderField: "Range") == "bytes=64-79")
    #expect(captured.value(forHTTPHeaderField: "User-Agent") == "HLSCacheTests/1.0")
    #expect(body.count == 16)
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
@Test func networkClient_rangeRequest_rejectsUnexpectedStatusCode() async throws {
    let targetURL = try #require(URL(string: "https://cdn.example.com/video.ts"))
    let requestedRange = try #require(ByteRange(start: 0, endExclusive: 8))

    let client = ClosureNetworkClient { _ in
        let response = try #require(
            HTTPURLResponse(
                url: targetURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (Data(repeating: 0x01, count: 8), response)
    }

    do {
        _ = try await client.data(from: targetURL, byteRange: requestedRange)
        #expect(Bool(false))
    } catch let error as NetworkClientError {
        #expect(error == .unexpectedHTTPStatusCode(expected: 206, actual: 200))
    }
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
@Test func networkClient_rangeRequest_rejectsMismatchedPayloadLength() async throws {
    let targetURL = try #require(URL(string: "https://cdn.example.com/video.ts"))
    let requestedRange = try #require(ByteRange(start: 10, endExclusive: 20))

    let client = ClosureNetworkClient { _ in
        let response = try #require(
            HTTPURLResponse(
                url: targetURL,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (Data(repeating: 0x02, count: 5), response)
    }

    do {
        _ = try await client.data(from: targetURL, byteRange: requestedRange)
        #expect(Bool(false))
    } catch let error as NetworkClientError {
        #expect(error == .invalidRangeResponseLength(expected: 10, actual: 5))
    }
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
@Test func proxyCacheCoordinator_fetchRange_usesNetworkClientRangeAPI() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-network-client-coordinator")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let coreCache = CoreCache(baseDirectory: directory)
    let coordinator = ProxyCacheCoordinator(coreCache: coreCache)
    let targetURL = try #require(URL(string: "https://cdn.example.com/segment.ts"))
    let requestedRange = try #require(ByteRange(start: 128, endExclusive: 136))

    let recorder = RequestRecorder()
    let client = ClosureNetworkClient { request in
        await recorder.record(request)
        let response = try #require(
            HTTPURLResponse(
                url: targetURL,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (Data(repeating: 0xCD, count: 8), response)
    }

    let data = try await coordinator.fetchRange(
        from: targetURL,
        range: requestedRange,
        headers: ["X-Test": "1"],
        using: client
    )

    let captured = try #require(await recorder.latest())
    #expect(captured.value(forHTTPHeaderField: "Range") == "bytes=128-135")
    #expect(captured.value(forHTTPHeaderField: "X-Test") == "1")
    #expect(data == Data(repeating: 0xCD, count: 8))
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
@Test func urlSessionNetworkClient_usesProvidedSession() async throws {
    let expectedURL = try #require(URL(string: "https://example.com/ping"))
    let recorder = RequestRecorder()
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }

    let client = URLSessionNetworkClient(session: session) { _, request in
        await recorder.record(request)
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/plain"]
        ))
        return (Data("ok".utf8), response)
    }

    let request = URLRequest(url: expectedURL)
    let (data, response) = try await client.data(for: request)

    let captured = try #require(await recorder.latest())
    #expect(captured.url == expectedURL)
    #expect(data == Data("ok".utf8))
    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 200)
    #expect(http.url == expectedURL)
}
