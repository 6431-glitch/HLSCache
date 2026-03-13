import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum CoreCacheDirectoryLockError: Error, Equatable, Sendable {
    case directoryInUse(lockFilePath: String)
    case lockIOFailure(lockFilePath: String, code: Int32)
}

extension CoreCacheDirectoryLockError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .directoryInUse(lockFilePath):
            return "CoreCache directory is already owned by another active instance: \(lockFilePath)"
        case let .lockIOFailure(lockFilePath, code):
            return "CoreCache directory lock IO failed at \(lockFilePath) (errno=\(code))."
        }
    }
}

// Wraps a process-wide OS file lock and NSLock-protected reservation set.
final class DirectoryLock: @unchecked Sendable {
    private static let reservationLock = NSLock()
    private nonisolated(unsafe) static var reservedLockFilePaths: Set<String> = []

    private let lockFilePath: String
    private let fileDescriptor: Int32

    init(baseDirectory: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let lockFileURL = baseDirectory.appendingPathComponent(".corecache.lock")
        let lockFilePath = lockFileURL.standardizedFileURL.path

        try Self.reserve(lockFilePath: lockFilePath)
        do {
            let descriptor = open(lockFilePath, O_CREAT | O_RDWR, 0o644)
            guard descriptor >= 0 else {
                throw CoreCacheDirectoryLockError.lockIOFailure(lockFilePath: lockFilePath, code: errno)
            }

            if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                let errorCode = errno
                _ = close(descriptor)
                if errorCode == EWOULDBLOCK || errorCode == EAGAIN {
                    throw CoreCacheDirectoryLockError.directoryInUse(lockFilePath: lockFilePath)
                }
                throw CoreCacheDirectoryLockError.lockIOFailure(lockFilePath: lockFilePath, code: errorCode)
            }

            self.lockFilePath = lockFilePath
            self.fileDescriptor = descriptor
        } catch {
            Self.unreserve(lockFilePath: lockFilePath)
            throw error
        }
    }

    deinit {
        _ = flock(fileDescriptor, LOCK_UN)
        _ = close(fileDescriptor)
        Self.unreserve(lockFilePath: lockFilePath)
    }

    private static func reserve(lockFilePath: String) throws {
        reservationLock.lock()
        defer { reservationLock.unlock() }

        guard !reservedLockFilePaths.contains(lockFilePath) else {
            throw CoreCacheDirectoryLockError.directoryInUse(lockFilePath: lockFilePath)
        }
        reservedLockFilePaths.insert(lockFilePath)
    }

    private static func unreserve(lockFilePath: String) {
        reservationLock.lock()
        reservedLockFilePaths.remove(lockFilePath)
        reservationLock.unlock()
    }
}
