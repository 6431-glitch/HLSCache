import CoreCache
import Foundation

public enum HLSCacheLogLevel: String, Equatable, Sendable {
    case debug
    case info
    case warning
    case error

    fileprivate init(_ level: StructuredLogLevel) {
        switch level {
        case .debug:
            self = .debug
        case .info:
            self = .info
        case .warning:
            self = .warning
        case .error:
            self = .error
        }
    }

    fileprivate var priority: Int {
        switch self {
        case .debug:
            return 0
        case .info:
            return 1
        case .warning:
            return 2
        case .error:
            return 3
        }
    }
}

public struct HLSCacheLogEvent: Equatable, Sendable {
    public let subsystem: String
    public let operation: String
    public let level: HLSCacheLogLevel
    public let correlationID: String
    public let metadata: [String: String]
    public let timestamp: Date

    public init(
        subsystem: String,
        operation: String,
        level: HLSCacheLogLevel,
        correlationID: String,
        metadata: [String: String],
        timestamp: Date
    ) {
        self.subsystem = subsystem
        self.operation = operation
        self.level = level
        self.correlationID = correlationID
        self.metadata = metadata
        self.timestamp = timestamp
    }

    fileprivate init(_ event: StructuredLogEvent) {
        self.init(
            subsystem: event.subsystem,
            operation: event.operation,
            level: HLSCacheLogLevel(event.level),
            correlationID: event.correlationID,
            metadata: event.metadata,
            timestamp: event.timestamp
        )
    }
}

/// Consumer-facing logging hook for HLSCache.
/// Implement this protocol in your app (for example, using Apple's `Logger`)
/// and pass it to `HLSCacheFacade` via `logConsumer:`.
public protocol HLSCacheLogConsumer: Sendable {
    func log(_ event: HLSCacheLogEvent)
}

public struct ClosureHLSCacheLogConsumer: HLSCacheLogConsumer {
    public typealias Handler = @Sendable (HLSCacheLogEvent) -> Void

    private let handler: Handler

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func log(_ event: HLSCacheLogEvent) {
        handler(event)
    }
}

public struct HLSCacheLogBridgeLogger: StructuredLogger {
    private let consumer: any HLSCacheLogConsumer
    private let minimumLevel: HLSCacheLogLevel

    public init(
        consumer: any HLSCacheLogConsumer,
        minimumLevel: HLSCacheLogLevel = .debug
    ) {
        self.consumer = consumer
        self.minimumLevel = minimumLevel
    }

    public func log(_ event: StructuredLogEvent) {
        let level = HLSCacheLogLevel(event.level)
        guard level.priority >= minimumLevel.priority else {
            return
        }
        consumer.log(HLSCacheLogEvent(event))
    }
}
