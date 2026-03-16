import CoreCache
import Foundation
import Testing
@testable import HLSCache

private func repositoryRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // HLSCacheTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
}

private func readRepositoryFile(_ relativePath: String) throws -> String {
    let fileURL = repositoryRootURL().appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
}

@Test func constantTimeCompareHexDigest_equalLengthBehavior_matchesExpectedParity() {
    #expect(constantTimeCompareHexDigest("abcdef1234", "abcdef1234") == true)
    #expect(constantTimeCompareHexDigest("abcdef1234", "abcdee1234") == false)
    #expect(constantTimeCompareHexDigest("abcdef", "abcdef00") == false)
}

@Test func constantTimeIntegrityEquals_enforcesAlgorithmAndDigestMatch() {
    let baseline = ResourceIntegrity(algorithm: "hmac-sha256-rfc2104-v1", digestHex: "abcdef123456")
    let same = ResourceIntegrity(algorithm: "hmac-sha256-rfc2104-v1", digestHex: "abcdef123456")
    let algorithmMismatch = ResourceIntegrity(algorithm: "hmac-sha256-v1", digestHex: "abcdef123456")
    let digestMismatch = ResourceIntegrity(algorithm: "hmac-sha256-rfc2104-v1", digestHex: "abcdee123456")

    #expect(constantTimeIntegrityEquals(baseline, same) == true)
    #expect(constantTimeIntegrityEquals(baseline, algorithmMismatch) == false)
    #expect(constantTimeIntegrityEquals(baseline, digestMismatch) == false)
    #expect(constantTimeIntegrityEquals(Optional(baseline), Optional(same)) == true)
    #expect(constantTimeIntegrityEquals(Optional(baseline), Optional<ResourceIntegrity>.none) == false)
}

@Test func integrityValidationPaths_useConstantTimeCompare_sourceContract() throws {
    let transformPipelineSource = try readRepositoryFile("Sources/HLSCache/TransformPipeline.swift")
    #expect(transformPipelineSource.contains("constantTimeIntegrityEquals(computedMetadata, storedIntegrity)"))

    let coordinatorSource = try readRepositoryFile("Sources/HLSCache/ProxyCacheCoordinator.swift")
    #expect(coordinatorSource.contains("constantTimeIntegrityEquals(storedIntegrity, computedIntegrity)"))

    let pluginSource = try readRepositoryFile("Sources/HLSCache/EncryptAtRestPlugin.swift")
    let helperUsageCount = pluginSource.components(separatedBy: "constantTimeCompareHexDigest(").count - 1
    #expect(helperUsageCount >= 2)
}
