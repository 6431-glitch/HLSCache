import Testing
@testable import HLSCache

@Test func directiveAttributeParser_tableDrivenVectors_coverQuotedCommaDuplicateKeysAndEmptyValues() throws {
    struct Vector {
        let name: String
        let line: String
        let expectedURIsInOrder: [String]
        let expectedURIFromMap: String?
        let expectedMethod: String?
        let expectedLanguage: String?
    }

    let vectors: [Vector] = [
        Vector(
            name: "quoted comma",
            line: #"#EXT-X-KEY:KEYFORMAT="identity",URI="keys/key.bin?token=a,b",METHOD=AES-128"#,
            expectedURIsInOrder: ["keys/key.bin?token=a,b"],
            expectedURIFromMap: "keys/key.bin?token=a,b",
            expectedMethod: "AES-128",
            expectedLanguage: nil
        ),
        Vector(
            name: "duplicate URI keys keep token order but map uses last value",
            line: #"#EXT-X-KEY:METHOD=AES-128,URI="keys/first.key",URI="keys/second.key""#,
            expectedURIsInOrder: ["keys/first.key", "keys/second.key"],
            expectedURIFromMap: "keys/second.key",
            expectedMethod: "AES-128",
            expectedLanguage: nil
        ),
        Vector(
            name: "empty URI and empty unquoted value",
            line: #"#EXT-X-MEDIA:TYPE=AUDIO,URI="",LANGUAGE=,GROUP-ID="aud""#,
            expectedURIsInOrder: [""],
            expectedURIFromMap: "",
            expectedMethod: nil,
            expectedLanguage: ""
        ),
        Vector(
            name: "unmatched quote drops malformed token in lenient mode",
            line: #"#EXT-X-KEY:METHOD=AES-128,URI="unterminated,IV=0x01"#,
            expectedURIsInOrder: [],
            expectedURIFromMap: nil,
            expectedMethod: "AES-128",
            expectedLanguage: nil
        )
    ]

    for vector in vectors {
        let attributes = HLSDirectiveAttributeParser.parseAfterDirectiveName(in: vector.line)
        let uriValues = attributes.filter { $0.key == "URI" }.map(\.value)
        #expect(uriValues == vector.expectedURIsInOrder, "\(vector.name) URI order mismatch")

        let map = HLSDirectiveAttributeParser.attributeMap(afterDirectiveNameIn: vector.line)
        #expect(map["URI"] == vector.expectedURIFromMap, "\(vector.name) map URI mismatch")
        #expect(map["METHOD"] == vector.expectedMethod, "\(vector.name) METHOD mismatch")
        #expect(map["LANGUAGE"] == vector.expectedLanguage, "\(vector.name) LANGUAGE mismatch")
    }
}

@Test func directiveAttributeParser_strictParsing_throwsForMalformedQuotedToken() {
    let line = #"#EXT-X-KEY:METHOD=AES-128,URI="unterminated,IV=0x01"#
    do {
        _ = try HLSDirectiveAttributeParser.parseAfterDirectiveNameStrict(in: line)
        #expect(Bool(false))
    } catch let error as HLSDirectiveAttributeParser.ParseError {
        #expect(error == .malformedQuotedAttribute)
    } catch {
        #expect(Bool(false))
    }
}
