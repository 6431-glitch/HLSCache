import CoreCache
import Foundation
import HLSCache

enum CLIExportError: Error, LocalizedError, Equatable {
    case aliasNotFound(String)
    case invalidOutputPath(String)
    case noCachedPlaylist(String)
    case incompleteCache(String)
    case ffmpegUnavailable(String)
    case remuxFailed(String)

    var errorDescription: String? {
        switch self {
        case let .aliasNotFound(alias):
            return "Alias '\(alias)' was not found."
        case let .invalidOutputPath(path):
            return "Invalid output path '\(path)'. Expected a .mp4 file path."
        case let .noCachedPlaylist(alias):
            return "No cached media playlist was found for alias '\(alias)'."
        case let .incompleteCache(reason):
            return "Cache is incomplete: \(reason)"
        case let .ffmpegUnavailable(reason):
            return "ffmpeg is unavailable: \(reason)"
        case let .remuxFailed(reason):
            return "MP4 remux failed: \(reason)"
        }
    }
}

struct CLIExportResult: Equatable {
    let outputURL: URL
    let outputBytes: Int64
}

struct CLIExporter {
    typealias ExportRunner = (_ playlistURL: URL, _ outputURL: URL, _ videoCodec: ExportVideoCodec) throws -> Void
    typealias EncoderAvailabilityChecker = (_ encoderName: String) throws -> Void

    private struct PlaylistCandidate {
        let playlistText: String
        let playlistURL: URL
        let segmentRemoteURLs: [URL]
        let mapRemoteURLs: [URL]
        let keyRemoteURLs: [URL]
    }

    private let baseDirectory: URL
    private let facade: HLSCacheFacade
    private let fileManager: FileManager
    private let exportRunner: ExportRunner
    private let encoderAvailabilityChecker: EncoderAvailabilityChecker

    init(
        baseDirectory: URL,
        facade: HLSCacheFacade,
        fileManager: FileManager = .default,
        exportRunner: @escaping ExportRunner = CLIExporter.defaultExportRunner,
        encoderAvailabilityChecker: @escaping EncoderAvailabilityChecker = CLIExporter.defaultEncoderAvailabilityChecker
    ) {
        self.baseDirectory = baseDirectory
        self.facade = facade
        self.fileManager = fileManager
        self.exportRunner = exportRunner
        self.encoderAvailabilityChecker = encoderAvailabilityChecker
    }

    func export(alias: String, outputURL: URL, videoCodec: ExportVideoCodec = .copy) throws -> CLIExportResult {
        guard outputURL.pathExtension.lowercased() == "mp4" else {
            throw CLIExportError.invalidOutputPath(outputURL.path)
        }

        guard let asset = facade.listAliases().first(where: { $0.alias == alias }) else {
            throw CLIExportError.aliasNotFound(alias)
        }

        let manifestStore = ManifestStore(baseDirectory: baseDirectory)
        let diskStore = DiskStore(baseDirectory: baseDirectory)
        let records = manifestStore.allRecords().filter { $0.resourceID.cacheKey == asset.cacheKey }
        let recordsByResource = Dictionary(uniqueKeysWithValues: records.map { ($0.resourceID, $0.record) })

        let playlists = records.filter { $0.resourceID.kind == .playlistM3U8 }
        guard !playlists.isEmpty else {
            throw CLIExportError.noCachedPlaylist(alias)
        }

        let candidate = try selectPlayablePlaylist(
            alias: alias,
            playlists: playlists,
            recordsByResource: recordsByResource,
            diskStore: diskStore
        )

        let outputDirectory = outputURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let stagingDirectory = baseDirectory
            .appendingPathComponent("export-staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        let mapFileNames = try copyResources(
            urls: candidate.mapRemoteURLs,
            prefix: "map",
            kind: .segment,
            cacheKey: asset.cacheKey,
            diskStore: diskStore,
            destinationDirectory: stagingDirectory
        )
        let segmentFileNames = try copyResources(
            urls: candidate.segmentRemoteURLs,
            prefix: "segment",
            kind: .segment,
            cacheKey: asset.cacheKey,
            diskStore: diskStore,
            destinationDirectory: stagingDirectory
        )
        let keyFileNames = try copyResources(
            urls: candidate.keyRemoteURLs,
            prefix: "key",
            kind: .key,
            cacheKey: asset.cacheKey,
            diskStore: diskStore,
            destinationDirectory: stagingDirectory
        )

        let rewrittenPlaylist = try rewritePlaylist(
            candidate.playlistText,
            playlistURL: candidate.playlistURL,
            mapFileNames: mapFileNames,
            keyFileNames: keyFileNames,
            segmentFileNames: segmentFileNames
        )
        let localPlaylistURL = stagingDirectory.appendingPathComponent("input.m3u8")
        try rewrittenPlaylist.write(to: localPlaylistURL, atomically: true, encoding: .utf8)

        if case .av1 = videoCodec {
            try encoderAvailabilityChecker("libsvtav1")
        }

        try exportRunner(localPlaylistURL, outputURL, videoCodec)

        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw CLIExportError.remuxFailed("Output file was not created.")
        }

        let attributes = try fileManager.attributesOfItem(atPath: outputURL.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return CLIExportResult(outputURL: outputURL, outputBytes: bytes)
    }

    private func selectPlayablePlaylist(
        alias: String,
        playlists: [StoredManifestRecord],
        recordsByResource: [ResourceID: ResourceRecord],
        diskStore: DiskStore
    ) throws -> PlaylistCandidate {
        var failureReasons: [String] = []
        var bestCandidate: PlaylistCandidate?

        for entry in playlists {
            let playlistResourceID = entry.resourceID
            guard isComplete(record: entry.record, resourceID: playlistResourceID, diskStore: diskStore) else {
                failureReasons.append("playlist \(playlistResourceID.resourceKey) is incomplete")
                continue
            }

            let playlistFileURL = diskStore.dataFileURL(for: playlistResourceID)
            guard let playlistData = try? Data(contentsOf: playlistFileURL),
                  let playlistText = String(data: playlistData, encoding: .utf8) else {
                failureReasons.append("playlist \(playlistResourceID.resourceKey) cannot be decoded as UTF-8")
                continue
            }

            guard playlistText.contains("#EXTINF") else {
                // Skip master playlists; export expects media playlist with segment durations.
                continue
            }

            let playlistURL = entry.record.originalURL
                ?? URL(string: "https://export.local/\(playlistResourceID.resourceKey).m3u8")!
            let parsed = HLSPlaylistParser.parse(playlistText, playlistURL: playlistURL)
            if parsed.segments.isEmpty {
                failureReasons.append("playlist does not contain media segments")
                continue
            }

            let mapRemoteURLs = try extractMapRemoteURLs(from: playlistText, playlistURL: playlistURL)
            let segmentRemoteURLs = parsed.segments.map(\.remoteURL)
            let keyRemoteURLs = parsed.keys
                .filter { $0.method?.uppercased() != "NONE" }
                .map(\.remoteURL)

            let missingSegment = (mapRemoteURLs + segmentRemoteURLs).first { remoteURL in
                let resourceID = ResourceID(
                    cacheKey: playlistResourceID.cacheKey,
                    kind: .segment,
                    resourceKey: ResourceID.makeResourceKey(from: remoteURL)
                )
                guard let record = recordsByResource[resourceID] else {
                    return true
                }
                return !isComplete(record: record, resourceID: resourceID, diskStore: diskStore)
            }

            if let missingSegment {
                failureReasons.append("missing or incomplete segment for \(missingSegment.absoluteString)")
                continue
            }

            let missingKey = keyRemoteURLs.first { remoteURL in
                let resourceID = ResourceID(
                    cacheKey: playlistResourceID.cacheKey,
                    kind: .key,
                    resourceKey: ResourceID.makeResourceKey(from: remoteURL)
                )
                guard let record = recordsByResource[resourceID] else {
                    return true
                }
                return !isComplete(record: record, resourceID: resourceID, diskStore: diskStore)
            }
            if let missingKey {
                failureReasons.append("missing or incomplete key for \(missingKey.absoluteString)")
                continue
            }

            let candidate = PlaylistCandidate(
                playlistText: playlistText,
                playlistURL: playlistURL,
                segmentRemoteURLs: segmentRemoteURLs,
                mapRemoteURLs: mapRemoteURLs,
                keyRemoteURLs: keyRemoteURLs
            )
            if bestCandidate == nil || candidate.segmentRemoteURLs.count > bestCandidate!.segmentRemoteURLs.count {
                bestCandidate = candidate
            }
        }

        if let bestCandidate {
            return bestCandidate
        }
        if let reason = failureReasons.first {
            throw CLIExportError.incompleteCache(reason)
        }
        throw CLIExportError.noCachedPlaylist(alias)
    }

    private func copyResources(
        urls: [URL],
        prefix: String,
        kind: ResourceKind,
        cacheKey: CacheKey,
        diskStore: DiskStore,
        destinationDirectory: URL
    ) throws -> [URL: String] {
        var output: [URL: String] = [:]
        for (index, remoteURL) in urls.enumerated() {
            let resourceID = ResourceID(
                cacheKey: cacheKey,
                kind: kind,
                resourceKey: ResourceID.makeResourceKey(from: remoteURL)
            )
            let sourceURL = diskStore.dataFileURL(for: resourceID)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw CLIExportError.incompleteCache("\(kind.rawValue) file missing at \(sourceURL.path)")
            }

            let ext = remoteURL.pathExtension.isEmpty ? "bin" : remoteURL.pathExtension
            let fileName = "\(prefix)-\(String(format: "%05d", index)).\(ext)"
            let destinationURL = destinationDirectory.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            output[remoteURL] = fileName
        }
        return output
    }

    private func rewritePlaylist(
        _ playlist: String,
        playlistURL: URL,
        mapFileNames: [URL: String],
        keyFileNames: [URL: String],
        segmentFileNames: [URL: String]
    ) throws -> String {
        let lines = playlist.components(separatedBy: .newlines)
        var rewritten: [String] = []
        rewritten.reserveCapacity(lines.count)

        var segmentIndex = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#EXT-X-KEY"),
               let keyURL = try resolveURIAttribute(in: line, relativeTo: playlistURL),
               let localName = keyFileNames[keyURL] {
                rewritten.append(replacingURIAttribute(in: line, with: localName))
                continue
            }

            if trimmed.hasPrefix("#EXT-X-MAP"),
               let mapURL = try resolveURIAttribute(in: line, relativeTo: playlistURL),
               let localName = mapFileNames[mapURL] {
                rewritten.append(replacingURIAttribute(in: line, with: localName))
                continue
            }

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                rewritten.append(line)
                continue
            }

            if segmentIndex < segmentFileNames.count {
                let remoteURL = try resolveNonCommentLine(line, playlistURL: playlistURL)
                if let localName = segmentFileNames[remoteURL] {
                    rewritten.append(localName)
                    segmentIndex += 1
                    continue
                }
            }

            rewritten.append(line)
        }

        return rewritten.joined(separator: "\n")
    }

    private func isComplete(record: ResourceRecord, resourceID: ResourceID, diskStore: DiskStore) -> Bool {
        let fileLength = (try? diskStore.fileLength(for: resourceID)) ?? 0
        let expected = record.expectedLength ?? fileLength
        guard expected > 0,
              fileLength >= expected,
              let fullRange = ByteRange(start: 0, endExclusive: expected) else {
            return false
        }
        return record.completedRanges.contains(fullRange)
    }

    private func extractMapRemoteURLs(from playlist: String, playlistURL: URL) throws -> [URL] {
        var urls: [URL] = []
        for line in playlist.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("#EXT-X-MAP") else {
                continue
            }
            if let mapURL = try resolveURIAttribute(in: line, relativeTo: playlistURL) {
                urls.append(mapURL)
            }
        }
        return urls
    }

    private func resolveURIAttribute(in line: String, relativeTo baseURL: URL) throws -> URL? {
        guard let uriRange = line.range(of: "URI=\"") else {
            return nil
        }
        let start = uriRange.upperBound
        guard let end = line[start...].firstIndex(of: "\"") else {
            throw CLIExportError.incompleteCache("Invalid playlist URI attribute in line: \(line)")
        }
        let raw = String(line[start..<end])
        guard let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL else {
            throw CLIExportError.incompleteCache("Invalid playlist URI value: \(raw)")
        }
        return url
    }

    private func replacingURIAttribute(in line: String, with value: String) -> String {
        guard let uriRange = line.range(of: "URI=\"") else {
            return line
        }
        let start = uriRange.upperBound
        guard let end = line[start...].firstIndex(of: "\"") else {
            return line
        }
        var rewritten = line
        rewritten.replaceSubrange(start..<end, with: value)
        return rewritten
    }

    private func resolveNonCommentLine(_ line: String, playlistURL: URL) throws -> URL {
        let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw, relativeTo: playlistURL)?.absoluteURL else {
            throw CLIExportError.incompleteCache("Invalid segment URI in playlist: \(raw)")
        }
        return url
    }

    static func defaultEncoderAvailabilityChecker(encoderName: String) throws {
        let (status, stderrOutput) = try runFFmpeg(
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-h", "encoder=\(encoderName)"
            ]
        )

        guard status == 0 else {
            if isFFmpegUnavailable(stderrOutput) {
                throw CLIExportError.ffmpegUnavailable(stderrOutput)
            }
            if stderrOutput.isEmpty {
                throw CLIExportError.ffmpegUnavailable(
                    "ffmpeg encoder '\(encoderName)' is not available. Install ffmpeg with \(encoderName) support, or rerun export without --av1."
                )
            }
            throw CLIExportError.ffmpegUnavailable(stderrOutput)
        }
    }

    static func defaultExportRunner(playlistURL: URL, outputURL: URL, videoCodec: ExportVideoCodec) throws {
        var arguments = commonFFmpegInputArguments(playlistURL: playlistURL)

        switch videoCodec {
        case .copy:
            arguments += ["-c", "copy"]
        case let .av1(options):
            arguments += [
                "-c:v", "libsvtav1",
                "-preset", options.preset,
                "-crf", String(options.crf)
            ]
            if let bitrate = options.bitrate {
                arguments += ["-b:v", bitrate]
            }
            arguments += ["-c:a", "copy"]
        }

        arguments.append(outputURL.path)
        let (status, stderrOutput) = try runFFmpeg(arguments: arguments)

        guard status == 0 else {
            if isFFmpegUnavailable(stderrOutput) {
                throw CLIExportError.ffmpegUnavailable(stderrOutput)
            }
            if stderrOutput.isEmpty {
                throw CLIExportError.remuxFailed("ffmpeg exited with status \(status)")
            }
            throw CLIExportError.remuxFailed(stderrOutput)
        }
    }

    private static func commonFFmpegInputArguments(playlistURL: URL) -> [String] {
        [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-allowed_extensions", "ALL",
            "-protocol_whitelist", "file,crypto,data",
            "-i", playlistURL.path
        ]
    }

    private static func runFFmpeg(arguments: [String]) throws -> (status: Int32, stderr: String) {
        let stderrPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg"] + arguments
        process.standardOutput = Pipe()
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw CLIExportError.ffmpegUnavailable(error.localizedDescription)
        }

        process.waitUntilExit()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrOutput = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return (process.terminationStatus, stderrOutput)
    }

    private static func isFFmpegUnavailable(_ stderrOutput: String) -> Bool {
        let lower = stderrOutput.lowercased()
        return (lower.contains("ffmpeg:") && lower.contains("not found"))
            || (lower.contains("no such file or directory") && lower.contains("ffmpeg"))
    }
}
