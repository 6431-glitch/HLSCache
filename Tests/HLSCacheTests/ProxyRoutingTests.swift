import Foundation
import Testing
@testable import HLSCache

@Test func proxyRoute_from_parsesKeyAndRawKinds() throws {
    let keyURL = try #require(URL(string: "http://127.0.0.1:8080/MD0534/key/https%3A%2F%2Fcdn.example.com%2Fenc.key%3Fv%3D1"))
    let keyRoute = try ProxyRoute.from(url: keyURL)
    #expect(keyRoute.alias == "MD0534")
    #expect(keyRoute.kind == .key)
    #expect(keyRoute.remoteURL.absoluteString == "https://cdn.example.com/enc.key?v=1")

    let rawURL = try #require(URL(string: "http://127.0.0.1:8080/MD0534/raw/https%3A%2F%2Fcdn.example.com%2Fmovie.mp4"))
    let rawRoute = try ProxyRoute.from(url: rawURL)
    #expect(rawRoute.kind == .raw)
    #expect(rawRoute.remoteURL.absoluteString == "https://cdn.example.com/movie.mp4")
}

@Test func proxyRoute_from_prefixedPath_parsesTrailingRouteComponents() throws {
    let prefixedURL = try #require(
        URL(string: "http://127.0.0.1:8080/proxy/v1/MD0534/seg/https%3A%2F%2Fcdn.example.com%2Fv.ts%3Ftoken%3Dabc")
    )

    let route = try ProxyRoute.from(url: prefixedURL)
    #expect(route.alias == "MD0534")
    #expect(route.kind == .segment)
    #expect(route.remoteURL.absoluteString == "https://cdn.example.com/v.ts?token=abc")
}

@Test func proxyRoute_from_unescapedRemoteURLPath_parsesExpandedRemoteSegments() throws {
    let unescapedURL = try #require(
        URL(string: "http://127.0.0.1:8080/MD0534/raw/https://cdn.example.com/path/to/master.m3u8")
    )

    let route = try ProxyRoute.from(url: unescapedURL)
    #expect(route.alias == "MD0534")
    #expect(route.kind == .raw)
    #expect(route.remoteURL.absoluteString == "https://cdn.example.com/path/to/master.m3u8")
}

@Test func proxyRoute_from_invalidPath_throws() throws {
    let invalidURL = try #require(URL(string: "http://127.0.0.1:8080/MD0534/seg"))

    do {
        _ = try ProxyRoute.from(url: invalidURL)
        #expect(Bool(false))
    } catch let error as ProxyRouteError {
        #expect(error == .invalidRoutePath("/MD0534/seg"))
    }
}

@Test func proxyRoute_from_unknownKind_throws() throws {
    let invalidURL = try #require(URL(string: "http://127.0.0.1:8080/MD0534/playlist/https%3A%2F%2Fcdn.example.com%2Fmaster.m3u8"))

    do {
        _ = try ProxyRoute.from(url: invalidURL)
        #expect(Bool(false))
    } catch let error as ProxyRouteError {
        #expect(error == .unsupportedRouteKind("playlist"))
    }
}

@Test func proxyRoute_from_malformedEncodedURL_throws() throws {
    let invalidURL = try #require(URL(string: "http://127.0.0.1:8080/MD0534/seg/https%3A%2F%2Fcdn.example.com%2Fsegment%ZZts"))

    do {
        _ = try ProxyRoute.from(url: invalidURL)
        #expect(Bool(false))
    } catch let error as ProxyRouteError {
        if case .invalidEncodedURL = error {
            #expect(Bool(true))
        } else {
            #expect(Bool(false))
        }
    }
}
