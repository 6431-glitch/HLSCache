import Foundation

public struct StructuredLogEvent: Equatable, Sendable {
    public let subsystem: String
    public let operation: String
    public let metadata: [String: String]
    public let timestamp: Date

    public init(
        subsystem: String,
        operation: String,
        metadata: [String: String] = [:],
        timestamp: Date = Date()
    ) {
        self.subsystem = subsystem
        self.operation = operation
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
