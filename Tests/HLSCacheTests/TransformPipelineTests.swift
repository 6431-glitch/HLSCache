import CoreCache
import Foundation
import Testing
@testable import HLSCache

private enum TransformPipelineTestError: Error, Equatable {
    case boom
}

private struct UppercasePlugin: ByteTransformer {
    let id: String = "uppercase"
    let version: String = "1.0.0"

    func makeStreamTransformer(context: TransformContext) -> any ByteStreamTransformer {
        UppercaseTransformer()
    }
}

private struct SegmentSuffixPlugin: ByteTransformer {
    let id: String = "segment-suffix"
    let version: String = "1.0.0"

    func supports(kind: ResourceKind) -> Bool {
        kind == .segment
    }

    func makeStreamTransformer(context: TransformContext) -> any ByteStreamTransformer {
        SuffixTransformer(suffix: Data("-seg".utf8))
    }
}

private struct FailingPlugin: ByteTransformer {
    let id: String = "failing"
    let version: String = "1.0.0"

    func makeStreamTransformer(context: TransformContext) -> any ByteStreamTransformer {
        FailingTransformer()
    }
}

private struct LegacyPlugin: HLSCachePlugin {
    let id: String = "legacy"
    let version: String = "0.9.0"
}

private struct UppercaseTransformer: ByteStreamTransformer {
    func transform(_ chunk: Data, isFinal: Bool) throws -> Data {
        Data(String(decoding: chunk, as: UTF8.self).uppercased().utf8)
    }
}

private struct SuffixTransformer: ByteStreamTransformer {
    let suffix: Data

    func transform(_ chunk: Data, isFinal: Bool) throws -> Data {
        var output = Data()
        output.reserveCapacity(chunk.count + suffix.count)
        output.append(chunk)
        output.append(suffix)
        return output
    }
}

private struct FailingTransformer: ByteStreamTransformer {
    func transform(_ chunk: Data, isFinal: Bool) throws -> Data {
        throw TransformPipelineTestError.boom
    }
}

private func makeTransformContext(kind: ResourceKind = .segment) -> TransformContext {
    TransformContext(
        resourceID: ResourceID(
            cacheKey: CacheKey.fromAssetID("asset-transform-pipeline"),
            kind: kind,
            resourceKey: "resource-key"
        )
    )
}

@Test func transformPipeline_withoutTransformers_passthroughsInput() throws {
    let pipeline = TransformPipeline()
    let processor = pipeline.makeProcessor(context: makeTransformContext())

    let input = Data("hello".utf8)
    let output = try processor.process(input, isFinal: true)
    #expect(output == input)
    #expect(processor.pluginStamps.isEmpty)
}

@Test func transformPipeline_appliesTransformersInOrder_andFiltersByResourceKind() throws {
    let pipeline = TransformPipeline(transformers: [UppercasePlugin(), SegmentSuffixPlugin()])
    let segmentProcessor = pipeline.makeProcessor(context: makeTransformContext(kind: .segment))
    let keyProcessor = pipeline.makeProcessor(context: makeTransformContext(kind: .key))

    let segmentOutput = try segmentProcessor.process(Data("abc".utf8))
    #expect(String(decoding: segmentOutput, as: UTF8.self) == "ABC-seg")
    #expect(segmentProcessor.pluginStamps == [
        PluginStamp(id: "uppercase", version: "1.0.0"),
        PluginStamp(id: "segment-suffix", version: "1.0.0")
    ])

    let keyOutput = try keyProcessor.process(Data("abc".utf8))
    #expect(String(decoding: keyOutput, as: UTF8.self) == "ABC")
    #expect(keyProcessor.pluginStamps == [
        PluginStamp(id: "uppercase", version: "1.0.0")
    ])
}

@Test func transformPipeline_failingTransformer_bubblesError() throws {
    let pipeline = TransformPipeline(transformers: [FailingPlugin()])
    let processor = pipeline.makeProcessor(context: makeTransformContext())

    do {
        _ = try processor.process(Data("test".utf8))
        #expect(Bool(false))
    } catch let error as TransformPipelineTestError {
        #expect(error == .boom)
    }
}

@Test func facade_makeTransformPipeline_includesOnlyByteTransformers() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hlscache-transform-pipeline-facade")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let facade = HLSCacheFacade(baseDirectory: directory)
    _ = facade.setPlugins([LegacyPlugin(), NoopPlugin()])

    let pipeline = facade.makeTransformPipeline()
    let processor = pipeline.makeProcessor(context: makeTransformContext())
    let output = try processor.process(Data("xyz".utf8), isFinal: true)

    #expect(String(decoding: output, as: UTF8.self) == "xyz")
    #expect(processor.pluginStamps == [PluginStamp(id: "noop", version: "1.0.0")])
    #expect(facade.activePlugins().count == 2)
}

@Test func encryptAtRestPlugin_roundTrip_encryptsOnWriteAndDecryptsOnRead() throws {
    let key = Data("local-test-key".utf8)
    let plugin = EncryptAtRestPlugin(key: key)
    let pipeline = TransformPipeline(transformers: [plugin])
    let context = makeTransformContext(kind: .segment)

    let plaintext = Data("hello-transform-pipeline".utf8)
    let writeProcessor = pipeline.makeProcessor(context: context, direction: .writeToCache)
    let encrypted = try writeProcessor.process(plaintext, isFinal: true)

    #expect(encrypted != plaintext)

    let readProcessor = pipeline.makeProcessor(context: context, direction: .readFromCache)
    let decrypted = try readProcessor.process(encrypted, isFinal: true)
    #expect(decrypted == plaintext)
}

@Test func encryptAtRestPlugin_usesByteOffsetForDeterministicRangeDecryption() throws {
    let key = Data("offset-aware-key".utf8)
    let plugin = EncryptAtRestPlugin(key: key)
    let pipeline = TransformPipeline(transformers: [plugin])

    let fullContext = makeTransformContext(kind: .other)
    let fullPlaintext = Data("0123456789abcdefghijklmnop".utf8)

    let fullWrite = pipeline.makeProcessor(context: fullContext, direction: .writeToCache)
    let encryptedFull = try fullWrite.process(fullPlaintext, isFinal: true)

    let sliceStart: Int64 = 8
    let sliceEnd: Int64 = 20
    let encryptedSlice = Data(encryptedFull[Int(sliceStart)..<Int(sliceEnd)])
    let sliceContext = TransformContext(resourceID: fullContext.resourceID, byteOffset: sliceStart)

    let sliceRead = pipeline.makeProcessor(context: sliceContext, direction: .readFromCache)
    let decryptedSlice = try sliceRead.process(encryptedSlice, isFinal: true)

    #expect(decryptedSlice == Data(fullPlaintext[Int(sliceStart)..<Int(sliceEnd)]))
}
