import Foundation

public struct ProgressEvent: Sendable, Equatable {
    public enum Operation: String, Sendable {
        case download
        case export
        case clear
    }

    public enum State: String, Sendable {
        case started
        case running
        case completed
        case failed
        case cancelled
    }

    public let operation: Operation
    public let state: State
    public let processedUnits: Int
    public let totalUnits: Int
    public let bytesWritten: Int64?
    public let detail: String?

    public init(
        operation: Operation,
        state: State,
        processedUnits: Int = 0,
        totalUnits: Int = 0,
        bytesWritten: Int64? = nil,
        detail: String? = nil
    ) {
        self.operation = operation
        self.state = state
        self.processedUnits = processedUnits
        self.totalUnits = totalUnits
        self.bytesWritten = bytesWritten
        self.detail = detail
    }
}
