import CoreCache
import Foundation

public enum ProxyResourceKind: String, CaseIterable, Sendable {
    case segment = "seg"
    case key
    case raw

    var coreCacheKind: ResourceKind {
        switch self {
        case .segment:
            return .segment
        case .key:
            return .key
        case .raw:
            return .other
        }
    }
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
    // a trailing route shape `<alias>/<kind>/<remote-url>`, where the remote URL
    // may be percent-encoded as one path component or expanded with "/" separators.
    static func parse(pathComponents: [Substring], originalPath: String) throws -> ProxyRoute {
        let nonEmptyComponents = pathComponents.filter { !$0.isEmpty }
        guard nonEmptyComponents.count >= 3 else {
            throw ProxyRouteError.invalidRoutePath(originalPath)
        }

        var sawKnownKind = false
        var invalidRemoteComponent: String?

        for index in pathComponents.indices.reversed() {
            guard let kind = ProxyResourceKind(rawValue: String(pathComponents[index])) else {
                continue
            }
            sawKnownKind = true
            guard index > pathComponents.startIndex else {
                continue
            }

            let aliasIndex = pathComponents.index(before: index)
            let aliasComponent = String(pathComponents[aliasIndex])
            guard !aliasComponent.isEmpty else {
                continue
            }

            let remoteStart = pathComponents.index(after: index)
            guard remoteStart < pathComponents.endIndex else {
                continue
            }

            let remoteComponent = pathComponents[remoteStart...].map(String.init).joined(separator: "/")
            guard !remoteComponent.isEmpty else {
                continue
            }

            let alias = try decodePathComponent(aliasComponent)
            let decodedRemoteURLString = remoteComponent.removingPercentEncoding ?? remoteComponent
            guard let remoteURL = URL(string: decodedRemoteURLString), remoteURL.scheme != nil else {
                invalidRemoteComponent = remoteComponent
                continue
            }

            return ProxyRoute(alias: alias, kind: kind, remoteURL: remoteURL)
        }

        if sawKnownKind {
            throw ProxyRouteError.invalidEncodedURL(invalidRemoteComponent ?? originalPath)
        }

        let fallbackKindIndex = nonEmptyComponents.index(nonEmptyComponents.endIndex, offsetBy: -2)
        let fallbackKindComponent = String(nonEmptyComponents[fallbackKindIndex])
        throw ProxyRouteError.unsupportedRouteKind(fallbackKindComponent)
    }

    public static func from(url: URL) throws -> ProxyRoute {
        let percentEncodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let components = percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
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
