import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum DiskStoreError: Error, Equatable, Sendable {
    case negativeOffset(Int64)
}

public final class DiskStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let baseDirectory: URL
    private let readChunkSize: Int
    private let queue = DispatchQueue(label: "CoreCache.DiskStore", attributes: .concurrent)

    public init(baseDirectory: URL, readChunkSize: Int = 64 * 1024) {
        self.fileManager = .default
        self.baseDirectory = baseDirectory
        self.readChunkSize = max(readChunkSize, 1)
    }

    public func dataFileURL(for resourceID: ResourceID) -> URL {
        baseDirectory
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent(resourceID.cacheKey.rawValue, isDirectory: true)
            .appendingPathComponent("resources", isDirectory: true)
            .appendingPathComponent(resourceID.kind.rawValue, isDirectory: true)
            .appendingPathComponent("\(resourceID.resourceKey).bin")
    }

    @discardableResult
    public func write(_ data: Data, for resourceID: ResourceID, at offset: Int64) throws -> ByteRange {
        guard offset >= 0 else {
            throw DiskStoreError.negativeOffset(offset)
        }

        return try queue.sync(flags: .barrier) {
            let fileURL = dataFileURL(for: resourceID)
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let fd = try openFileDescriptor(path: fileURL.path, flags: O_RDWR | O_CREAT, mode: 0o644)
            defer { _ = close(fd) }

            try pwriteAll(fd: fd, data: data, offset: offset)

            let endExclusive = offset + Int64(data.count)
            guard let writtenRange = ByteRange(start: offset, endExclusive: endExclusive) else {
                preconditionFailure("Invalid write range for offset=\(offset) count=\(data.count)")
            }
            return writtenRange
        }
    }

    public func read(resourceID: ResourceID, range: ByteRange) throws -> Data {
        try queue.sync {
            guard range.length > 0 else {
                return Data()
            }

            let fileURL = dataFileURL(for: resourceID)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                return Data()
            }

            let fileLength = try fileLength(at: fileURL)
            guard range.start < fileLength else {
                return Data()
            }

            let endExclusive = min(range.endExclusive, fileLength)
            guard endExclusive > range.start else {
                return Data()
            }

            guard let byteCount = Int(exactly: endExclusive - range.start) else {
                return Data()
            }
            let fd = try openFileDescriptor(path: fileURL.path, flags: O_RDONLY, mode: 0)
            defer { _ = close(fd) }
            return try readFromFileDescriptor(fd, startOffset: range.start, byteCount: byteCount)
        }
    }

    public func fileLength(for resourceID: ResourceID) throws -> Int64 {
        try queue.sync {
            let fileURL = dataFileURL(for: resourceID)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                return 0
            }
            return try fileLength(at: fileURL)
        }
    }

    public func remove(resourceID: ResourceID) throws {
        try queue.sync(flags: .barrier) {
            let fileURL = dataFileURL(for: resourceID)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                return
            }
            try fileManager.removeItem(at: fileURL)
        }
    }

    func allStoredResourceIDs() -> [ResourceID] {
        queue.sync {
            let cacheDirectory = baseDirectory.appendingPathComponent("cache", isDirectory: true)
            guard fileManager.fileExists(atPath: cacheDirectory.path) else {
                return []
            }

            guard let enumerator = fileManager.enumerator(
                at: cacheDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }

            let cacheComponents = cacheDirectory.resolvingSymlinksInPath().pathComponents
            var resourceIDs: [ResourceID] = []
            resourceIDs.reserveCapacity(32)

            for case let fileURL as URL in enumerator {
                guard let resourceID = resourceID(
                    from: fileURL,
                    under: cacheComponents,
                    fileExtension: "bin"
                ) else {
                    continue
                }
                resourceIDs.append(resourceID)
            }

            return resourceIDs
        }
    }

    private func readFromFileDescriptor(_ fd: Int32, startOffset: Int64, byteCount: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(min(byteCount, readChunkSize * 4))

        var remaining = byteCount
        var currentOffset = startOffset
        while remaining > 0 {
            let chunkSize = min(remaining, readChunkSize)
            let chunk = try preadChunk(fd: fd, offset: currentOffset, count: chunkSize)
            guard !chunk.isEmpty else {
                break
            }

            data.append(chunk)
            remaining -= chunk.count
            currentOffset += Int64(chunk.count)
        }

        return data
    }

    private func fileLength(at fileURL: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func openFileDescriptor(path: String, flags: Int32, mode: mode_t) throws -> Int32 {
        let fd = open(path, flags, mode)
        guard fd >= 0 else {
            throw currentPOSIXError()
        }
        return fd
    }

    private func pwriteAll(fd: Int32, data: Data, offset: Int64) throws {
        if data.isEmpty {
            return
        }

        var written = 0
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            while written < data.count {
                let bytesRemaining = data.count - written
                let writeOffset = off_t(offset + Int64(written))

                let result = pwrite(fd, baseAddress.advanced(by: written), bytesRemaining, writeOffset)
                if result < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw currentPOSIXError()
                }
                if result == 0 {
                    throw currentPOSIXError(code: EIO)
                }

                written += result
            }
        }
    }

    private func preadChunk(fd: Int32, offset: Int64, count: Int) throws -> Data {
        if count <= 0 {
            return Data()
        }

        var buffer = [UInt8](repeating: 0, count: count)
        while true {
            let result = pread(fd, &buffer, count, off_t(offset))
            if result < 0 {
                if errno == EINTR {
                    continue
                }
                throw currentPOSIXError()
            }
            if result == 0 {
                return Data()
            }
            return Data(buffer.prefix(result))
        }
    }

    private func currentPOSIXError(code: Int32? = nil) -> POSIXError {
        let value = code ?? errno
        return POSIXError(POSIXErrorCode(rawValue: value) ?? .EIO)
    }

    private func resourceID(
        from fileURL: URL,
        under cacheComponents: [String],
        fileExtension: String
    ) -> ResourceID? {
        guard fileURL.pathExtension == fileExtension else {
            return nil
        }

        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            return nil
        }

        let fileComponents = fileURL.resolvingSymlinksInPath().pathComponents
        guard fileComponents.count >= cacheComponents.count,
              Array(fileComponents.prefix(cacheComponents.count)) == cacheComponents else {
            return nil
        }

        let components = Array(fileComponents.dropFirst(cacheComponents.count))
        guard components.count == 4,
              components[1] == "resources",
              let kind = ResourceKind(rawValue: components[2]) else {
            return nil
        }

        let resourceKey = URL(fileURLWithPath: components[3]).deletingPathExtension().lastPathComponent
        return ResourceID(
            cacheKey: CacheKey(rawValue: components[0]),
            kind: kind,
            resourceKey: resourceKey
        )
    }
}
