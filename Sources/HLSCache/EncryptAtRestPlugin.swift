import CoreCache
import Foundation

public enum EncryptAtRestPluginError: Error, Equatable, Hashable, Sendable {
    case invalidKey(reason: String)
}

public struct EncryptAtRestPlugin: HLSCachePlugin, ReversibleByteTransformer, IntegrityMetadataTransformer, Hashable, Sendable {
    public enum Mode: String, Hashable, Sendable {
        case xorInsecure
        case authenticatedV1

        fileprivate var pluginID: String {
            switch self {
            case .xorInsecure:
                return "encrypt-at-rest"
            case .authenticatedV1:
                return "encrypt-at-rest-authenticated"
            }
        }

        fileprivate var defaultVersion: String {
            switch self {
            case .xorInsecure:
                return "1.0.0"
            case .authenticatedV1:
                return "2.0.0-auth-v1"
            }
        }
    }

    public let id: String
    public let version: String
    public let mode: Mode
    private let keyData: Data
    private let validationError: EncryptAtRestPluginError?

    public init(key: Data, mode: Mode = .xorInsecure, version: String? = nil) {
        self.mode = mode
        self.id = mode.pluginID
        self.version = version ?? mode.defaultVersion
        if key.isEmpty {
            self.keyData = Data([0])
            self.validationError = .invalidKey(reason: "EncryptAtRestPlugin requires a non-empty key")
        } else {
            self.keyData = key
            self.validationError = nil
        }
    }

    public func makeStreamTransformer(context: TransformContext) -> any ByteStreamTransformer {
        makeStreamTransformer(context: context, direction: .writeToCache)
    }

    public func makeStreamTransformer(
        context: TransformContext,
        direction: TransformDirection
    ) -> any ByteStreamTransformer {
        if let validationError {
            return InvalidEncryptAtRestConfigurationTransformer(error: validationError)
        }

        switch mode {
        case .xorInsecure:
            return XORCipherStreamTransformer(
                keyBytes: Array(keyData),
                initialOffset: context.byteOffset
            )
        case .authenticatedV1:
            return AuthenticatedStreamCipherTransformer(
                keyData: keyData,
                resourceKeyData: Data(context.resourceID.resourceKey.utf8),
                initialOffset: context.byteOffset
            )
        }
    }

    public func integrityMetadata(for cachedPayload: Data, context: TransformContext) throws -> ResourceIntegrity? {
        if let validationError {
            throw validationError
        }

        guard mode == .authenticatedV1 else {
            return nil
        }

        return ResourceIntegrity(
            algorithm: "hmac-sha256-v1",
            digestHex: Self.integrityDigestHex(
                keyData: keyData,
                resourceKeyData: Data(context.resourceID.resourceKey.utf8),
                cachedPayload: cachedPayload
            )
        )
    }

    fileprivate static func keystreamBlock(
        keyData: Data,
        resourceKeyData: Data,
        blockIndex: UInt64
    ) -> [UInt8] {
        var message = Data("hlscache-auth-enc-v1".utf8)
        message.append(keyData)
        message.append(resourceKeyData)
        var index = blockIndex.bigEndian
        withUnsafeBytes(of: &index) { message.append(contentsOf: $0) }
        message.append(keyData)
        return sha256Bytes(message)
    }

    private static func integrityDigestHex(
        keyData: Data,
        resourceKeyData: Data,
        cachedPayload: Data
    ) -> String {
        var message = Data("hlscache-auth-integrity-v1".utf8)
        message.append(keyData)
        message.append(resourceKeyData)
        message.append(cachedPayload)
        message.append(keyData)
        let digest = sha256Bytes(message)
        return hexString(digest)
    }

    private static func sha256Bytes(_ data: Data) -> [UInt8] {
        let hex = SHA256Hex.digest(data)
        var output: [UInt8] = []
        output.reserveCapacity(hex.count / 2)

        let scalars = Array(hex.unicodeScalars)
        var index = 0
        while index + 1 < scalars.count {
            guard let high = hexNibble(scalars[index]),
                  let low = hexNibble(scalars[index + 1]) else {
                break
            }
            output.append(UInt8((high << 4) | low))
            index += 2
        }

        return output
    }

    private static func hexNibble(_ scalar: UnicodeScalar) -> Int? {
        switch scalar.value {
        case 48...57:
            return Int(scalar.value - 48)
        case 97...102:
            return Int(scalar.value - 87)
        case 65...70:
            return Int(scalar.value - 55)
        default:
            return nil
        }
    }

    private static func hexString(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var output = [UInt8]()
        output.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
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

private final class AuthenticatedStreamCipherTransformer: ByteStreamTransformer, @unchecked Sendable {
    private let keyData: Data
    private let resourceKeyData: Data
    private let lock = NSLock()
    private var offset: Int64

    init(keyData: Data, resourceKeyData: Data, initialOffset: Int64) {
        self.keyData = keyData
        self.resourceKeyData = resourceKeyData
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

        let absoluteOffset = max(Int64(0), offset)
        let stream = makeKeystream(length: chunk.count, absoluteOffset: absoluteOffset)
        let chunkBytes = [UInt8](chunk)

        var transformed = Data()
        transformed.reserveCapacity(chunk.count)
        for index in chunkBytes.indices {
            transformed.append(chunkBytes[index] ^ stream[index])
        }
        return transformed
    }

    private func makeKeystream(length: Int, absoluteOffset: Int64) -> [UInt8] {
        if length == 0 {
            return []
        }

        let blockSize = 32
        let firstBlock = Int(absoluteOffset / Int64(blockSize))
        let firstBlockSkip = Int(absoluteOffset % Int64(blockSize))

        var stream: [UInt8] = []
        stream.reserveCapacity(length)

        var blockCursor = firstBlock
        var skipInBlock = firstBlockSkip

        while stream.count < length {
            let block = EncryptAtRestPlugin.keystreamBlock(
                keyData: keyData,
                resourceKeyData: resourceKeyData,
                blockIndex: UInt64(blockCursor)
            )
            let start = min(skipInBlock, block.count)
            if start < block.count {
                let remaining = length - stream.count
                let end = min(block.count, start + remaining)
                stream.append(contentsOf: block[start..<end])
            }

            blockCursor += 1
            skipInBlock = 0
        }

        return stream
    }
}

private struct InvalidEncryptAtRestConfigurationTransformer: ByteStreamTransformer {
    let error: EncryptAtRestPluginError

    func transform(_ chunk: Data, isFinal: Bool) throws -> Data {
        throw error
    }
}
