import CoreCache
import Foundation

public protocol ByteStreamTransformer: Sendable {
    func transform(_ chunk: Data, isFinal: Bool) throws -> Data
}

public enum TransformDirection: Sendable, Equatable {
    case writeToCache
    case readFromCache
}

public protocol ByteTransformer: HLSCachePlugin {
    func supports(kind: ResourceKind) -> Bool
    func makeStreamTransformer(context: TransformContext) -> any ByteStreamTransformer
}

public protocol ReversibleByteTransformer: ByteTransformer {
    func makeStreamTransformer(context: TransformContext, direction: TransformDirection) -> any ByteStreamTransformer
}

public protocol IntegrityMetadataTransformer: ByteTransformer {
    func integrityMetadata(for cachedPayload: Data, context: TransformContext) throws -> ResourceIntegrity?
}

public protocol IntegrityMetadataCompatibilityTransformer: ByteTransformer {
    func isStoredIntegrityCompatible(
        _ storedIntegrity: ResourceIntegrity,
        cachedPayload: Data,
        context: TransformContext
    ) throws -> Bool
}

extension ByteTransformer {
    public func supports(kind: ResourceKind) -> Bool {
        true
    }
}

public struct TransformContext: Sendable, Equatable {
    public let resourceID: ResourceID
    public let byteOffset: Int64

    public init(resourceID: ResourceID, byteOffset: Int64 = 0) {
        self.resourceID = resourceID
        self.byteOffset = byteOffset
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

    public func makeProcessor(
        context: TransformContext,
        direction: TransformDirection = .writeToCache
    ) -> TransformPipelineProcessor {
        let applicable = transformers.filter { $0.supports(kind: context.resourceID.kind) }
        let streamTransformers = applicable.map { plugin -> any ByteStreamTransformer in
            if let reversible = plugin as? any ReversibleByteTransformer {
                return reversible.makeStreamTransformer(context: context, direction: direction)
            }
            return plugin.makeStreamTransformer(context: context)
        }
        let stamps = applicable.map { PluginStamp(id: $0.id, version: $0.version) }
        return TransformPipelineProcessor(streamTransformers: streamTransformers, pluginStamps: stamps)
    }

    public func integrityMetadata(
        for cachedPayload: Data,
        context: TransformContext
    ) throws -> ResourceIntegrity? {
        let applicable = transformers.filter { $0.supports(kind: context.resourceID.kind) }
        for transformer in applicable {
            guard let integrityTransformer = transformer as? any IntegrityMetadataTransformer else {
                continue
            }
            if let metadata = try integrityTransformer.integrityMetadata(for: cachedPayload, context: context) {
                return metadata
            }
        }
        return nil
    }

    public func storedIntegrityMatches(
        _ storedIntegrity: ResourceIntegrity,
        cachedPayload: Data,
        context: TransformContext
    ) throws -> Bool? {
        let applicable = transformers.filter { $0.supports(kind: context.resourceID.kind) }
        for transformer in applicable {
            guard let integrityTransformer = transformer as? any IntegrityMetadataTransformer else {
                continue
            }

            guard let computedMetadata = try integrityTransformer.integrityMetadata(
                for: cachedPayload,
                context: context
            ) else {
                continue
            }

            if let compatibilityTransformer = transformer as? any IntegrityMetadataCompatibilityTransformer {
                return try compatibilityTransformer.isStoredIntegrityCompatible(
                    storedIntegrity,
                    cachedPayload: cachedPayload,
                    context: context
                )
            }

            return computedMetadata == storedIntegrity
        }

        return nil
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
