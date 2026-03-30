import Foundation
import Logging

public typealias StructuredLogLevel = Logger.Level

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

public protocol Loggable: Sendable {
    var logger: Logger { get }
}

public extension Loggable {
    static var logger: Logger {
        Logger(label: String(reflecting: Self.self))
    }

    var logger: Logger {
        Self.logger
    }
}

public struct NoOpLogHandler: LogHandler {
    public var metadata: Logger.Metadata = [:]
    public var logLevel: Logger.Level = .critical

    public init() {}

    public subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get { metadata[metadataKey] }
        set { metadata[metadataKey] = newValue }
    }

    public func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source _: String,
        file _: String,
        function _: String,
        line _: UInt
    ) {}
}

public extension Logger {
    static func hlsNoOp(label: String) -> Logger {
        Logger(label: label) { _ in NoOpLogHandler() }
    }

    func log(_ event: StructuredLogEvent) {
        guard event.level >= logLevel else {
            return
        }

        var fields: Logger.Metadata = [
            "subsystem": .string(event.subsystem),
            "operation": .string(event.operation),
            "correlationID": .string(event.correlationID),
            "timestampMs": .string(String(Int64(event.timestamp.timeIntervalSince1970 * 1_000)))
        ]

        for (key, value) in event.metadata {
            fields[key] = .string(value)
        }

        log(level: event.level, "\(event.operation)", metadata: fields)
    }
}

public struct NoOpLoggable: Loggable {
    public let logger: Logger

    public init(label: String = "HLSCache.NoOp") {
        self.logger = .hlsNoOp(label: label)
    }
}

extension Logger: Loggable {
    public var logger: Logger { self }
}
