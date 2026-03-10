import Foundation

public struct NoopPlugin: HLSCachePlugin, Hashable, Sendable {
    public let id: String
    public let version: String

    public init(version: String = "1.0.0") {
        self.id = "noop"
        self.version = version
    }
}
