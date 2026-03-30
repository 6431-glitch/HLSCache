import CoreCache
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class BackgroundURLSessionDownloadCoordinator: @unchecked Sendable {
    public let recoveryCoordinator: BackgroundDownloadRecoveryCoordinator

    public init(
        baseDirectory: URL,
        recoveryCoordinator: BackgroundDownloadRecoveryCoordinator? = nil,
        logger: any Loggable = NoOpLoggable()
    ) {
        self.recoveryCoordinator = recoveryCoordinator
            ?? BackgroundDownloadRecoveryCoordinator(baseDirectory: baseDirectory, logger: logger)
    }

    @discardableResult
    public func registerDownloadTask(
        _ task: URLSessionDownloadTask,
        resourceID: ResourceID,
        remoteURL: URL,
        contentType: String? = nil,
        expectedLength: Int64? = nil,
        clearContentType: Bool = false,
        clearExpectedLength: Bool = false
    ) throws -> BackgroundDownloadTaskRecord {
        try recoveryCoordinator.registerTask(
            taskIdentifier: task.taskIdentifier,
            resourceID: resourceID,
            remoteURL: remoteURL,
            contentType: contentType,
            expectedLength: expectedLength,
            clearContentType: clearContentType,
            clearExpectedLength: clearExpectedLength
        )
    }

    public func taskRecord(for task: URLSessionTask) -> BackgroundDownloadTaskRecord? {
        recoveryCoordinator.taskRecord(for: task.taskIdentifier)
    }

    public func recoverPendingTasks(activeTasks: [URLSessionTask]) throws -> [BackgroundDownloadTaskRecord] {
        try recoveryCoordinator.recoverPendingTasks(
            activeTaskIdentifiers: Set(activeTasks.map(\.taskIdentifier))
        )
    }

    @discardableResult
    public func completeDownload(
        task: URLSessionDownloadTask,
        temporaryFileURL: URL,
        response: URLResponse? = nil
    ) throws -> BackgroundDownloadRecoveryResult {
        let contentType = response?.mimeType
        var expectedLength: Int64?
        if let response, response.expectedContentLength > 0 {
            expectedLength = response.expectedContentLength
        }

        return try recoveryCoordinator.completeDownload(
            taskIdentifier: task.taskIdentifier,
            temporaryFileURL: temporaryFileURL,
            contentType: contentType,
            expectedLength: expectedLength
        )
    }
}
