import Logging
import Pulse
import PulseUI
import UIKit

private struct PulseForwardingLogHandler: LogHandler {
    let label: String
    var logLevel: Logger.Level = .info
    var metadata: Logger.Metadata = [:]

    private let store: LoggerStore

    init(label: String, store: LoggerStore = LoggerStore.shared) {
        self.label = label
        self.store = store
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        var mergedMetadata = self.metadata
        if let metadata {
            mergedMetadata.merge(metadata) { _, new in new }
        }

        let metadataSuffix = mergedMetadata.isEmpty ? "" : " \(mergedMetadata)"
        store.storeMessage(
            label: label,
            level: pulseLevel(for: level),
            message: "\(message)\(metadataSuffix)"
        )
    }

    private func pulseLevel(for level: Logger.Level) -> LoggerStore.Level {
        switch level {
        case .trace, .debug:
            return .debug
        case .info, .notice:
            return .info
        case .warning:
            return .warning
        case .error, .critical:
            return .error
        }
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    private static let bootstrapLogging: Void = {
        LoggingSystem.bootstrap { label in
            MultiplexLogHandler([
                StreamLogHandler.standardOutput(label: label),
                PulseForwardingLogHandler(label: label)
            ])
        }
    }()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        _ = Self.bootstrapLogging
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}
