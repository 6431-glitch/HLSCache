import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

public typealias Alias = String
public typealias AssetID = String

public struct CacheKey: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func fromAssetID(_ assetID: AssetID) -> CacheKey {
        let data = Data(assetID.utf8)
        return CacheKey(rawValue: SHA256Hex.digest(data))
    }
}

enum SHA256Hex {
    static func digest(_ data: Data) -> String {
        #if canImport(CryptoKit)
        if #available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *) {
            let digest = CryptoKit.SHA256.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        #endif
        return FallbackSHA256.hash(data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum FallbackSHA256 {
    static func hash(_ data: Data) -> [UInt8] {
        var message = Array(data)
        let bitLength = UInt64(message.count) * 8

        message.append(0x80)
        while (message.count % 64) != 56 {
            message.append(0)
        }

        message += [
            UInt8((bitLength >> 56) & 0xff),
            UInt8((bitLength >> 48) & 0xff),
            UInt8((bitLength >> 40) & 0xff),
            UInt8((bitLength >> 32) & 0xff),
            UInt8((bitLength >> 24) & 0xff),
            UInt8((bitLength >> 16) & 0xff),
            UInt8((bitLength >> 8) & 0xff),
            UInt8(bitLength & 0xff)
        ]

        var h0: UInt32 = 0x6a09e667
        var h1: UInt32 = 0xbb67ae85
        var h2: UInt32 = 0x3c6ef372
        var h3: UInt32 = 0xa54ff53a
        var h4: UInt32 = 0x510e527f
        var h5: UInt32 = 0x9b05688c
        var h6: UInt32 = 0x1f83d9ab
        var h7: UInt32 = 0x5be0cd19

        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
            0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
            0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
            0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
            0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
            0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
            0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
            0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
            0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
        ]

        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)

            for i in 0..<16 {
                let index = chunkStart + i * 4
                w[i] = (UInt32(message[index]) << 24)
                    | (UInt32(message[index + 1]) << 16)
                    | (UInt32(message[index + 2]) << 8)
                    | UInt32(message[index + 3])
            }

            for i in 16..<64 {
                let s0 = rotateRight(w[i - 15], by: 7) ^ rotateRight(w[i - 15], by: 18) ^ (w[i - 15] >> 3)
                let s1 = rotateRight(w[i - 2], by: 17) ^ rotateRight(w[i - 2], by: 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = h0
            var b = h1
            var c = h2
            var d = h3
            var e = h4
            var f = h5
            var g = h6
            var h = h7

            for i in 0..<64 {
                let s1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
                let ch = (e & f) ^ ((~e) & g)
                let temp1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj

                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
            h5 = h5 &+ f
            h6 = h6 &+ g
            h7 = h7 &+ h
        }

        let words = [h0, h1, h2, h3, h4, h5, h6, h7]
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)

        for word in words {
            bytes.append(UInt8((word >> 24) & 0xff))
            bytes.append(UInt8((word >> 16) & 0xff))
            bytes.append(UInt8((word >> 8) & 0xff))
            bytes.append(UInt8(word & 0xff))
        }

        return bytes
    }

    private static func rotateRight(_ x: UInt32, by n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}
