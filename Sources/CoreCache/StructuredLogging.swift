import Foundation

public enum StructuredLogLevel: String, Equatable, Sendable {
    case debug
    case info
    case warning
    case error
}

public struct StructuredLogEvent: Equatable, Sendable {
    public let subsystem: String
    public let operation: String
    public let level: StructuredLogLevel
    public let correlationID: String
    public let metadata: [String: String]
    public let timestamp: Date

    public init(
        subsystem: String,
        operation: String,
        level: StructuredLogLevel = .info,
        correlationID: String = UUID().uuidString,
        metadata: [String: String] = [:],
        timestamp: Date = Date()
    ) {
        self.subsystem = subsystem
        self.operation = operation
        self.level = level
        self.correlationID = correlationID
        self.metadata = metadata
        self.timestamp = timestamp
    }
}

public protocol StructuredLogger: Sendable {
    func log(_ event: StructuredLogEvent)
}

public struct NoopStructuredLogger: StructuredLogger {
    public init() {}
    public func log(_ event: StructuredLogEvent) {}
}
