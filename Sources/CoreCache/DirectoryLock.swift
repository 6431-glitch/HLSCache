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

final class DirectoryLock: @unchecked Sendable {
    private struct LockIdentityKey: Hashable {
        let deviceID: UInt64
        let inode: UInt64
    }

    private static let reservationLock = NSLock()
    private nonisolated(unsafe) static var reservedLockIdentityKeys: Set<LockIdentityKey> = []

    private let lockFilePath: String
    private let lockIdentityKey: LockIdentityKey
    private let fileDescriptor: Int32

    init(baseDirectory: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let canonicalBaseDirectory = baseDirectory.resolvingSymlinksInPath().standardizedFileURL
        let lockFileURL = canonicalBaseDirectory.appendingPathComponent(".corecache.lock")
        let lockFilePath = lockFileURL.path

        let descriptor = open(lockFilePath, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            throw CoreCacheDirectoryLockError.lockIOFailure(lockFilePath: lockFilePath, code: errno)
        }

        do {
            let lockIdentityKey = try Self.makeLockIdentityKey(
                fileDescriptor: descriptor,
                lockFilePath: lockFilePath
            )
            try Self.reserve(lockIdentityKey: lockIdentityKey, lockFilePath: lockFilePath)

            if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                let errorCode = errno
                Self.unreserve(lockIdentityKey: lockIdentityKey)
                if errorCode == EWOULDBLOCK || errorCode == EAGAIN {
                    throw CoreCacheDirectoryLockError.directoryInUse(lockFilePath: lockFilePath)
                }
                throw CoreCacheDirectoryLockError.lockIOFailure(lockFilePath: lockFilePath, code: errorCode)
            }

            self.lockFilePath = lockFilePath
            self.lockIdentityKey = lockIdentityKey
            self.fileDescriptor = descriptor
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    deinit {
        _ = flock(fileDescriptor, LOCK_UN)
        _ = close(fileDescriptor)
        Self.unreserve(lockIdentityKey: lockIdentityKey)
    }

    private static func reserve(lockIdentityKey: LockIdentityKey, lockFilePath: String) throws {
        reservationLock.lock()
        defer { reservationLock.unlock() }

        guard !reservedLockIdentityKeys.contains(lockIdentityKey) else {
            throw CoreCacheDirectoryLockError.directoryInUse(lockFilePath: lockFilePath)
        }
        reservedLockIdentityKeys.insert(lockIdentityKey)
    }

    private static func unreserve(lockIdentityKey: LockIdentityKey) {
        reservationLock.lock()
        reservedLockIdentityKeys.remove(lockIdentityKey)
        reservationLock.unlock()
    }

    private static func makeLockIdentityKey(
        fileDescriptor: Int32,
        lockFilePath: String
    ) throws -> LockIdentityKey {
        var fileStatus = stat()
        guard fstat(fileDescriptor, &fileStatus) == 0 else {
            throw CoreCacheDirectoryLockError.lockIOFailure(lockFilePath: lockFilePath, code: errno)
        }

        return LockIdentityKey(deviceID: UInt64(fileStatus.st_dev), inode: UInt64(fileStatus.st_ino))
    }
}
