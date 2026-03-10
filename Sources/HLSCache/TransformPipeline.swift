import CoreCache
import Foundation

public protocol ByteStreamTransformer: Sendable {
    func transform(_ chunk: Data, isFinal: Bool) throws -> Data
}

public protocol ByteTransformer: HLSCachePlugin {
    func supports(kind: ResourceKind) -> Bool
    func makeStreamTransformer(context: TransformContext) -> any ByteStreamTransformer
}

extension ByteTransformer {
    public func supports(kind: ResourceKind) -> Bool {
        true
    }
}

public struct TransformContext: Sendable, Equatable {
    public let resourceID: ResourceID

    public init(resourceID: ResourceID) {
        self.resourceID = resourceID
    }
}

public final class TransformPipeline: @unchecked Sendable {
    private let transformers: [any ByteTransformer]

    public init(transformers: [any ByteTransformer]) {
        self.transformers = transformers
    }

    public convenience init() {
        self.init(transformers: [])
    }

    public func makeProcessor(context: TransformContext) -> TransformPipelineProcessor {
        let applicable = transformers.filter { $0.supports(kind: context.resourceID.kind) }
        let streamTransformers = applicable.map { $0.makeStreamTransformer(context: context) }
        let stamps = applicable.map { PluginStamp(id: $0.id, version: $0.version) }
        return TransformPipelineProcessor(streamTransformers: streamTransformers, pluginStamps: stamps)
    }
}

public final class TransformPipelineProcessor: @unchecked Sendable {
    private let streamTransformers: [any ByteStreamTransformer]
    public let pluginStamps: [PluginStamp]

    init(streamTransformers: [any ByteStreamTransformer], pluginStamps: [PluginStamp]) {
        self.streamTransformers = streamTransformers
        self.pluginStamps = pluginStamps
    }

    public func process(_ chunk: Data, isFinal: Bool = false) throws -> Data {
        var transformed = chunk
        for transformer in streamTransformers {
            transformed = try transformer.transform(transformed, isFinal: isFinal)
        }
        return transformed
    }
}
