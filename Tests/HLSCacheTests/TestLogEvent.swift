import Foundation
import Logging

struct StructuredLogEvent: Equatable, Sendable {
    let subsystem: String
    let operation: String
    let level: Logger.Level
    let correlationID: String
    let metadata: [String: String]
    let timestamp: Date
}
