import Foundation

enum CLIAV1BitrateValidator {
    static let guidance = "Use a positive integer plus unit suffix k or M (examples: 1200k, 2M)."

    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isValid(_ value: String) -> Bool {
        value.range(of: "^[1-9][0-9]*[kKmM]$", options: .regularExpression) != nil
    }
}
