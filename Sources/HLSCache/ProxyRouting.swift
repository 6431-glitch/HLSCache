import CoreCache
import Foundation

public enum ProxyResourceKind: String, CaseIterable, Sendable {
    case segment = "seg"
    case key
    case raw
}

public struct ProxyRoute: Equatable, Sendable {
    public let alias: Alias
    public let kind: ProxyResourceKind
    public let remoteURL: URL

    public init(alias: Alias, kind: ProxyResourceKind, remoteURL: URL) {
        self.alias = alias
        self.kind = kind
        self.remoteURL = remoteURL
    }

    static var pathComponentAllowedCharacters: CharacterSet {
        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    }

    static func encodePathComponent(_ value: String) throws -> String {
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: pathComponentAllowedCharacters) else {
            throw ProxyRouteError.invalidEncodedURL(value)
        }
        return encoded
    }

    static func decodePathComponent(_ value: String) throws -> String {
        guard let decoded = value.removingPercentEncoding else {
            throw ProxyRouteError.invalidEncodedURL(value)
        }
        return decoded
    }

    static func parse(pathComponents: [Substring], originalPath: String) throws -> ProxyRoute {
        guard pathComponents.count == 3 else {
            throw ProxyRouteError.invalidRoutePath(originalPath)
        }

        let alias = try decodePathComponent(String(pathComponents[0]))
        guard let kind = ProxyResourceKind(rawValue: String(pathComponents[1])) else {
            throw ProxyRouteError.unsupportedRouteKind(String(pathComponents[1]))
        }

        let decodedURL = try decodePathComponent(String(pathComponents[2]))
        guard let remoteURL = URL(string: decodedURL), remoteURL.scheme != nil else {
            throw ProxyRouteError.invalidEncodedURL(String(pathComponents[2]))
        }

        return ProxyRoute(alias: alias, kind: kind, remoteURL: remoteURL)
    }

    public static func from(url: URL) throws -> ProxyRoute {
        let percentEncodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let components = percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        return try parse(pathComponents: components, originalPath: percentEncodedPath)
    }

    public func encodedAlias() throws -> String {
        try Self.encodePathComponent(alias)
    }

    public func encodedRemoteURL() throws -> String {
        try Self.encodePathComponent(remoteURL.absoluteString)
    }
}

public enum ProxyRouteError: Error, Equatable, Sendable {
    case invalidRoutePath(String)
    case unsupportedRouteKind(String)
    case invalidEncodedURL(String)
}
