import Foundation

public struct EncryptAtRestPlugin: HLSCachePlugin, ReversibleByteTransformer, Hashable, Sendable {
    public let id: String
    public let version: String
    private let keyBytes: [UInt8]

    public init(key: Data, version: String = "1.0.0") {
        precondition(!key.isEmpty, "EncryptAtRestPlugin requires a non-empty key")
        self.id = "encrypt-at-rest"
        self.version = version
        self.keyBytes = Array(key)
    }

    public func makeStreamTransformer(context: TransformContext) -> any ByteStreamTransformer {
        makeStreamTransformer(context: context, direction: .writeToCache)
    }

    public func makeStreamTransformer(
        context: TransformContext,
        direction: TransformDirection
    ) -> any ByteStreamTransformer {
        XORCipherStreamTransformer(
            keyBytes: keyBytes,
            initialOffset: context.byteOffset
        )
    }
}

private final class XORCipherStreamTransformer: ByteStreamTransformer, @unchecked Sendable {
    private let keyBytes: [UInt8]
    private let lock = NSLock()
    private var offset: Int64

    init(keyBytes: [UInt8], initialOffset: Int64) {
        self.keyBytes = keyBytes
        self.offset = initialOffset
    }

    func transform(_ chunk: Data, isFinal: Bool) throws -> Data {
        if chunk.isEmpty {
            return Data()
        }

        lock.lock()
        defer {
            offset += Int64(chunk.count)
            lock.unlock()
        }

        var transformed = Data()
        transformed.reserveCapacity(chunk.count)

        let count = keyBytes.count
        let chunkBytes = [UInt8](chunk)
        for (index, byte) in chunkBytes.enumerated() {
            let keyIndex = Int((offset + Int64(index)) % Int64(count))
            transformed.append(byte ^ keyBytes[keyIndex])
        }

        return transformed
    }
}
