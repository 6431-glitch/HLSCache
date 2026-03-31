import Foundation
import Logging

public protocol HLSLoggable: Sendable {
    var logger: Logger { get }
}

public extension HLSLoggable {
    static var logger: Logger { Logger(label: String(reflecting: Self.self)) }
    var logger: Logger { Self.logger }
}
