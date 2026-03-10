import Foundation

public struct NoopPlugin: HLSCachePlugin, ByteTransformer, Hashable, Sendable {
    public let id: String
    public let version: String

    public init(version: String = "1.0.0") {
        self.id = "noop"
        self.version = version
    }

    public func makeStreamTransformer(context: TransformContext) -> any ByteStreamTransformer {
        NoopByteStreamTransformer()
    }
}

private struct NoopByteStreamTransformer: ByteStreamTransformer {
    func transform(_ chunk: Data, isFinal: Bool) throws -> Data {
        chunk
    }
}
