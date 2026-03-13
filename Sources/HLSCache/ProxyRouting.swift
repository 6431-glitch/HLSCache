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

    // Route-prefix policy:
    // The parser accepts optional leading deployment prefixes and interprets
    // the trailing 3 components as `<alias>/<kind>/<encoded-remote-url>`.
    static func parse(pathComponents: [Substring], originalPath: String) throws -> ProxyRoute {
        guard pathComponents.count >= 3 else {
            throw ProxyRouteError.invalidRoutePath(originalPath)
        }

        let routeTail = pathComponents.suffix(3)
        let aliasComponent = String(routeTail[routeTail.startIndex])
        let kindComponent = String(routeTail[routeTail.index(routeTail.startIndex, offsetBy: 1)])
        let remoteComponent = String(routeTail[routeTail.index(routeTail.startIndex, offsetBy: 2)])

        let alias = try decodePathComponent(aliasComponent)
        guard let kind = ProxyResourceKind(rawValue: kindComponent) else {
            throw ProxyRouteError.unsupportedRouteKind(kindComponent)
        }

        let decodedURL = try decodePathComponent(remoteComponent)
        guard let remoteURL = URL(string: decodedURL), remoteURL.scheme != nil else {
            throw ProxyRouteError.invalidEncodedURL(remoteComponent)
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
