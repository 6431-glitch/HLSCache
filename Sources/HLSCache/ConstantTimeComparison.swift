import CoreCache
import Foundation

// Constant-time compare for equal-length digests used in integrity validation paths.
func constantTimeCompareHexDigest(_ lhs: String, _ rhs: String) -> Bool {
    let lhsBytes = Array(lhs.utf8)
    let rhsBytes = Array(rhs.utf8)
    guard lhsBytes.count == rhsBytes.count else {
        return false
    }

    var mismatch: UInt8 = 0
    for index in lhsBytes.indices {
        mismatch |= lhsBytes[index] ^ rhsBytes[index]
    }
    return mismatch == 0
}

func constantTimeIntegrityEquals(_ lhs: ResourceIntegrity, _ rhs: ResourceIntegrity) -> Bool {
    guard lhs.algorithm == rhs.algorithm else {
        return false
    }
    return constantTimeCompareHexDigest(lhs.digestHex, rhs.digestHex)
}

func constantTimeIntegrityEquals(_ lhs: ResourceIntegrity?, _ rhs: ResourceIntegrity?) -> Bool {
    switch (lhs, rhs) {
    case let (lhs?, rhs?):
        return constantTimeIntegrityEquals(lhs, rhs)
    case (nil, nil):
        return true
    default:
        return false
    }
}
