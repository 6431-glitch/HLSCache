import Foundation

func parseOperationAndMetadata(from message: String) -> (operation: String, metadata: [String: String]) {
    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
        return ("", [:])
    }

    let operation: String
    let dictionarySlice: Substring?
    if let bracketIndex = text.firstIndex(of: "["), bracketIndex > text.startIndex {
        let before = text.index(before: bracketIndex)
        if text[before] == " " {
            operation = String(text[..<before]).trimmingCharacters(in: .whitespacesAndNewlines)
            dictionarySlice = text[bracketIndex...]
        } else {
            operation = text
            dictionarySlice = nil
        }
    } else {
        operation = text
        dictionarySlice = nil
    }

    let normalizedOperation = normalizeOperation(operation)

    guard let dictionarySlice else {
        return (normalizedOperation, [:])
    }

    let pattern = #""([^"]+)"\s*:\s*"([^"]*)""#
    let regex = try? NSRegularExpression(pattern: pattern)
    let nsText = String(dictionarySlice) as NSString
    let matches = regex?.matches(in: String(dictionarySlice), range: NSRange(location: 0, length: nsText.length)) ?? []
    var parsed: [String: String] = [:]
    for match in matches where match.numberOfRanges == 3 {
        let key = nsText.substring(with: match.range(at: 1))
        let value = nsText.substring(with: match.range(at: 2))
        parsed[key] = value
    }
    return (normalizedOperation, parsed)
}

private func normalizeOperation(_ operation: String) -> String {
    let lowered = operation.lowercased()

    if lowered.contains("listing aliases returned") {
        return "listAliases"
    }
    if lowered.contains("updated remote url for alias") {
        return "updateRemoteURL"
    }
    if lowered.contains("proxy request") || lowered.contains("proxy stream") {
        return "proxyRequest"
    }
    if lowered.contains("recovered alias registry") || lowered.contains("failed to recover alias registry") {
        return "loadAliasRegistry"
    }
    if lowered.contains("recovered background task registry") || lowered.contains("failed to recover background task registry") {
        return "loadBackgroundDownloadTaskRegistry"
    }
    if lowered.contains("background startup reconciliation") || lowered.contains("orphan background") {
        return "reconcileBackgroundStartup"
    }
    if lowered.contains("recovered corrupted manifest") || lowered.contains("failed to recover corrupted manifest") {
        return "manifestDecodeRecovery"
    }
    if lowered.contains("startup reconciliation") || lowered.contains("removed orphan manifest") || lowered.contains("removed orphan data file") {
        return "reconcileStartup"
    }
    if lowered.contains("planned read for resource") {
        return "plan"
    }
    if lowered.contains("wrote ") && lowered.contains(" byte(s) to resource ") {
        return "write"
    }
    if lowered.contains("finalized write for resource") {
        return "finalizeWrite"
    }
    if lowered.contains("plugin migration decision") {
        return "pluginMigrationDecision"
    }
    if lowered.contains("invalidated resource") {
        return "invalidateResource"
    }
    if lowered.contains("evicted resource") {
        return "evict"
    }

    return operation
}
