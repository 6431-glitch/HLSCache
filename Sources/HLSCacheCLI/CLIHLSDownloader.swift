import CoreCache
import Foundation
import HLSCache

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum CLIDownloadError: Error, LocalizedError {
    case aliasNotFound(String)
    case requestFailed(url: URL, statusCode: Int?, reason: String)
    case invalidPlaylistEncoding(URL)
    case responseMissing(URL)

    var errorDescription: String? {
        switch self {
        case let .aliasNotFound(alias):
            return "Alias '\(alias)' was not found."
        case let .requestFailed(url, statusCode, reason):
            if let statusCode {
                return "Request failed (\(statusCode)) for \(url.absoluteString): \(reason)"
            }
            return "Request failed for \(url.absoluteString): \(reason)"
        case let .invalidPlaylistEncoding(url):
            return "Playlist is not valid UTF-8: \(url.absoluteString)"
        case let .responseMissing(url):
            return "No response received for \(url.absoluteString)"
        }
    }
}

struct CLIDownloadResult: Equatable {
    let alias: String
    let playlistCount: Int
    let mediaPlaylistCount: Int
    let segmentCount: Int
    let keyCount: Int
    let bytesWritten: Int64
}

struct CLIDownloadProgress: Equatable {
    let processedUnits: Int
    let totalUnits: Int
    let bytesWritten: Int64
    let currentURL: URL
    let currentKind: ResourceKind
}

struct CLIDownloadPlan: Equatable {
    let playlistCount: Int
    let mediaPlaylistCount: Int
    let segmentCount: Int
    let keyCount: Int
    let totalUnits: Int
}

// Stores non-Sendable facade/cache handles but only accesses them through synchronized APIs.
struct CLIHLSDownloader: @unchecked Sendable {
    typealias Fetcher = (_ request: URLRequest) async throws -> (Data, URLResponse)
    typealias PlanHandler = @Sendable (_ plan: CLIDownloadPlan) -> Void
    typealias ProgressHandler = @Sendable (_ progress: CLIDownloadProgress) -> Void

    private struct FetchedResource {
        let data: Data
        let contentType: String?
    }

    private struct DiscoveryPlan {
        let playlistURLsInOrder: [URL]
        let mediaPlaylistCount: Int
        let keyURLs: [URL]
        let segmentURLs: [URL]
        let fetchedPlaylists: [String: FetchedResource]

        var totalResources: Int {
            playlistURLsInOrder.count + keyURLs.count + segmentURLs.count
        }
    }

    private let baseDirectory: URL
    private let facade: HLSCacheFacade
    private let diskStore: DiskStore
    private let manifestStore: ManifestStore
    private let fetcher: Fetcher

    init(
        baseDirectory: URL,
        facade: HLSCacheFacade,
        diskStore: DiskStore? = nil,
        manifestStore: ManifestStore? = nil,
        fetcher: @escaping Fetcher = CLIHLSDownloader.defaultFetcher
    ) {
        self.baseDirectory = baseDirectory
        self.facade = facade
        self.diskStore = diskStore ?? DiskStore(baseDirectory: baseDirectory)
        self.manifestStore = manifestStore ?? ManifestStore(baseDirectory: baseDirectory)
        self.fetcher = fetcher
    }

    func download(
        alias: String,
        planHandler: PlanHandler? = nil,
        progressHandler: ProgressHandler? = nil
    ) async throws -> CLIDownloadResult {
        guard let asset = facade.listAliases().first(where: { $0.alias == alias }) else {
            throw CLIDownloadError.aliasNotFound(alias)
        }

        let plan = try await buildDiscoveryPlan(rootURL: asset.currentRemoteURL, headers: asset.headers)

        let playlistCount = plan.playlistURLsInOrder.count
        let mediaPlaylistCount = plan.mediaPlaylistCount
        let segmentCount = plan.segmentURLs.count
        let keyCount = plan.keyURLs.count
        let totalUnits = plan.totalResources
        planHandler?(
            CLIDownloadPlan(
                playlistCount: playlistCount,
                mediaPlaylistCount: mediaPlaylistCount,
                segmentCount: segmentCount,
                keyCount: keyCount,
                totalUnits: totalUnits
            )
        )

        var processedUnits = 0
        var bytesWritten: Int64 = 0

        for playlistURL in plan.playlistURLsInOrder {
            try checkCancellationIfSupported()
            let playlistKey = canonicalURLKey(for: playlistURL)
            guard let fetchedPlaylist = plan.fetchedPlaylists[playlistKey] else {
                throw CLIDownloadError.responseMissing(playlistURL)
            }
            let playlistData = fetchedPlaylist.data

            _ = try storeResource(
                url: playlistURL,
                kind: .playlistM3U8,
                cacheKey: asset.cacheKey,
                data: playlistData,
                contentType: fetchedPlaylist.contentType
            )
            processedUnits += 1
            bytesWritten += Int64(playlistData.count)
            progressHandler?(
                CLIDownloadProgress(
                    processedUnits: processedUnits,
                    totalUnits: totalUnits,
                    bytesWritten: bytesWritten,
                    currentURL: playlistURL,
                    currentKind: .playlistM3U8
                )
            )
        }

        for keyURL in plan.keyURLs {
            try checkCancellationIfSupported()
            let fetchedKey = try await fetchResource(url: keyURL, headers: asset.headers)
            _ = try storeResource(
                url: keyURL,
                kind: .key,
                cacheKey: asset.cacheKey,
                data: fetchedKey.data,
                contentType: fetchedKey.contentType
            )
            processedUnits += 1
            bytesWritten += Int64(fetchedKey.data.count)
            progressHandler?(
                CLIDownloadProgress(
                    processedUnits: processedUnits,
                    totalUnits: totalUnits,
                    bytesWritten: bytesWritten,
                    currentURL: keyURL,
                    currentKind: .key
                )
            )
        }

        for segmentURL in plan.segmentURLs {
            try checkCancellationIfSupported()
            let fetchedSegment = try await fetchResource(url: segmentURL, headers: asset.headers)
            _ = try storeResource(
                url: segmentURL,
                kind: .segment,
                cacheKey: asset.cacheKey,
                data: fetchedSegment.data,
                contentType: fetchedSegment.contentType
            )
            processedUnits += 1
            bytesWritten += Int64(fetchedSegment.data.count)
            progressHandler?(
                CLIDownloadProgress(
                    processedUnits: processedUnits,
                    totalUnits: totalUnits,
                    bytesWritten: bytesWritten,
                    currentURL: segmentURL,
                    currentKind: .segment
                )
            )
        }

        return CLIDownloadResult(
            alias: alias,
            playlistCount: playlistCount,
            mediaPlaylistCount: mediaPlaylistCount,
            segmentCount: segmentCount,
            keyCount: keyCount,
            bytesWritten: bytesWritten
        )
    }

    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    func downloadProgressEvents(alias: String) -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            final class DownloadEventState: @unchecked Sendable {
                private let lock = NSLock()
                private var totalUnits = 0

                func setTotalUnits(_ totalUnits: Int) {
                    lock.lock()
                    self.totalUnits = totalUnits
                    lock.unlock()
                }

                func snapshotTotalUnits() -> Int {
                    lock.lock()
                    defer { lock.unlock() }
                    return totalUnits
                }
            }

            let state = DownloadEventState()
            continuation.yield(
                ProgressEvent(
                    operation: .download,
                    state: .started,
                    detail: "Starting download for alias \(alias)"
                )
            )

            Task {
                do {
                    let result = try await download(
                        alias: alias,
                        planHandler: { plan in
                            state.setTotalUnits(plan.totalUnits)
                            continuation.yield(
                                ProgressEvent(
                                    operation: .download,
                                    state: .running,
                                    processedUnits: 0,
                                    totalUnits: plan.totalUnits,
                                    detail: "Planned \(plan.totalUnits) resources"
                                )
                            )
                        },
                        progressHandler: { progress in
                            continuation.yield(
                                ProgressEvent(
                                    operation: .download,
                                    state: .running,
                                    processedUnits: progress.processedUnits,
                                    totalUnits: progress.totalUnits,
                                    bytesWritten: progress.bytesWritten,
                                    detail: "\(progress.currentKind.rawValue) \(progress.currentURL.lastPathComponent)"
                                )
                            )
                        }
                    )

                    let discoveredTotalUnits = state.snapshotTotalUnits()
                    let totalUnits = discoveredTotalUnits > 0 ? discoveredTotalUnits : (result.playlistCount + result.segmentCount + result.keyCount)
                    continuation.yield(
                        ProgressEvent(
                            operation: .download,
                            state: .completed,
                            processedUnits: totalUnits,
                            totalUnits: totalUnits,
                            bytesWritten: result.bytesWritten,
                            detail: "Download completed for alias \(alias)"
                        )
                    )
                    continuation.finish()
                } catch is CancellationError {
                    let discoveredTotalUnits = state.snapshotTotalUnits()
                    continuation.yield(
                        ProgressEvent(
                            operation: .download,
                            state: .cancelled,
                            processedUnits: 0,
                            totalUnits: discoveredTotalUnits,
                            detail: "Download cancelled for alias \(alias)"
                        )
                    )
                    continuation.finish(throwing: CancellationError())
                } catch {
                    let discoveredTotalUnits = state.snapshotTotalUnits()
                    continuation.yield(
                        ProgressEvent(
                            operation: .download,
                            state: .failed,
                            processedUnits: 0,
                            totalUnits: discoveredTotalUnits,
                            detail: error.localizedDescription
                        )
                    )
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    @available(
        *,
        deprecated,
        message: "Use downloadProgressEvents(alias:) and consume ProgressEvent as AsyncSequence."
    )
    @discardableResult
    func downloadLegacy(
        alias: String,
        planHandler: PlanHandler? = nil,
        progressHandler: ProgressHandler? = nil,
        completion: @escaping @Sendable (Result<CLIDownloadResult, Error>) -> Void
    ) -> Task<Void, Never> {
        Task {
            do {
                let result = try await download(
                    alias: alias,
                    planHandler: planHandler,
                    progressHandler: progressHandler
                )
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func buildDiscoveryPlan(rootURL: URL, headers: [String: String]?) async throws -> DiscoveryPlan {
        var pendingPlaylists: [URL] = [rootURL]
        var visitedPlaylists: Set<String> = []
        var playlistURLsInOrder: [URL] = []
        var fetchedPlaylists: [String: FetchedResource] = [:]
        var mediaPlaylistCount = 0

        var keyURLs: [URL] = []
        var keyURLKeys: Set<String> = []
        var segmentURLs: [URL] = []
        var segmentURLKeys: Set<String> = []

        while !pendingPlaylists.isEmpty {
            try checkCancellationIfSupported()
            let playlistURL = pendingPlaylists.removeFirst()
            let playlistKey = canonicalURLKey(for: playlistURL)
            guard visitedPlaylists.insert(playlistKey).inserted else {
                continue
            }

            let fetchedPlaylist = try await fetchResource(url: playlistURL, headers: headers)
            guard let playlistText = String(data: fetchedPlaylist.data, encoding: .utf8) else {
                throw CLIDownloadError.invalidPlaylistEncoding(playlistURL)
            }
            fetchedPlaylists[playlistKey] = fetchedPlaylist
            playlistURLsInOrder.append(playlistURL)

            let childPlaylists = try extractChildPlaylistURLs(from: playlistText, playlistURL: playlistURL)
            for childURL in childPlaylists {
                let childKey = canonicalURLKey(for: childURL)
                if !visitedPlaylists.contains(childKey) {
                    pendingPlaylists.append(childURL)
                }
            }

            if playlistText.contains("#EXTINF") {
                mediaPlaylistCount += 1
            }

            let parsed = HLSPlaylistParser.parse(playlistText, playlistURL: playlistURL)
            let mapURLs = try extractMapRemoteURLs(from: playlistText, playlistURL: playlistURL)

            for key in parsed.keys where key.method?.uppercased() != "NONE" {
                let keyURL = key.remoteURL
                let keyURLKey = canonicalURLKey(for: keyURL)
                if keyURLKeys.insert(keyURLKey).inserted {
                    keyURLs.append(keyURL)
                }
            }

            let discoveredSegmentURLs = parsed.segments.map(\.remoteURL) + mapURLs
            for segmentURL in discoveredSegmentURLs {
                if looksLikePlaylistURL(segmentURL) {
                    let segmentPlaylistKey = canonicalURLKey(for: segmentURL)
                    if !visitedPlaylists.contains(segmentPlaylistKey) {
                        pendingPlaylists.append(segmentURL)
                    }
                    continue
                }

                let segmentURLKey = canonicalURLKey(for: segmentURL)
                if segmentURLKeys.insert(segmentURLKey).inserted {
                    segmentURLs.append(segmentURL)
                }
            }
        }

        return DiscoveryPlan(
            playlistURLsInOrder: playlistURLsInOrder,
            mediaPlaylistCount: mediaPlaylistCount,
            keyURLs: keyURLs,
            segmentURLs: segmentURLs,
            fetchedPlaylists: fetchedPlaylists
        )
    }

    private func fetchResource(url: URL, headers: [String: String]?) async throws -> FetchedResource {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, value) in (headers ?? [:]) {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await fetcher(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            guard response.url != nil else {
                throw CLIDownloadError.responseMissing(url)
            }
            return FetchedResource(data: data, contentType: response.mimeType)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw CLIDownloadError.requestFailed(
                url: url,
                statusCode: httpResponse.statusCode,
                reason: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }

        return FetchedResource(data: data, contentType: response.mimeType)
    }

    private func storeResource(
        url: URL,
        kind: ResourceKind,
        cacheKey: CacheKey,
        data: Data,
        contentType: String?
    ) throws -> ResourceID {
        let resourceID = ResourceID(
            cacheKey: cacheKey,
            kind: kind,
            resourceKey: ResourceID.makeResourceKey(from: url)
        )

        try? diskStore.remove(resourceID: resourceID)
        _ = try diskStore.write(data, for: resourceID, at: 0)

        var completedRanges = IntervalSet()
        if let range = ByteRange(start: 0, endExclusive: Int64(data.count)) {
            completedRanges.insert(range)
        }

        let record = ResourceRecord(
            kind: kind,
            originalURL: url,
            contentType: contentType,
            expectedLength: Int64(data.count),
            completedRanges: completedRanges
        )
        try manifestStore.save(resourceID: resourceID, record: record)
        return resourceID
    }

    private func extractChildPlaylistURLs(from playlist: String, playlistURL: URL) throws -> [URL] {
        let lines = playlist.components(separatedBy: .newlines)
        var urls: [URL] = []

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            if trimmed.hasPrefix("#EXT-X-MEDIA"),
               let mediaURL = try resolveURIAttribute(in: line, relativeTo: playlistURL) {
                urls.append(mediaURL)
                continue
            }

            if trimmed.hasPrefix("#EXT-X-STREAM-INF") {
                var nextIndex = index + 1
                while nextIndex < lines.count {
                    let candidate = lines[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                    nextIndex += 1
                    guard !candidate.isEmpty else {
                        continue
                    }
                    if candidate.hasPrefix("#") {
                        continue
                    }
                    guard let childURL = URL(string: candidate, relativeTo: playlistURL)?.absoluteURL else {
                        break
                    }
                    urls.append(childURL)
                    break
                }
                continue
            }

            if trimmed.hasPrefix("#") {
                continue
            }

            if looksLikePlaylistPath(trimmed),
               let childURL = URL(string: trimmed, relativeTo: playlistURL)?.absoluteURL {
                urls.append(childURL)
            }
        }

        return urls
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
            throw CLIDownloadError.requestFailed(
                url: baseURL,
                statusCode: nil,
                reason: "Invalid URI attribute in line: \(line)"
            )
        }
        let raw = String(line[start..<end])
        guard let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL else {
            throw CLIDownloadError.requestFailed(
                url: baseURL,
                statusCode: nil,
                reason: "Invalid URI value '\(raw)'"
            )
        }
        return url
    }

    private func canonicalURLKey(for url: URL) -> String {
        ResourceID.makeResourceKey(from: url)
    }

    private func makeResourceID(url: URL, kind: ResourceKind, cacheKey: CacheKey) -> ResourceID {
        ResourceID(
            cacheKey: cacheKey,
            kind: kind,
            resourceKey: ResourceID.makeResourceKey(from: url)
        )
    }

    private func looksLikePlaylistURL(_ url: URL) -> Bool {
        let absolute = url.absoluteString.lowercased()
        return absolute.contains(".m3u8")
    }

    private func looksLikePlaylistPath(_ raw: String) -> Bool {
        raw.lowercased().contains(".m3u8")
    }

    private func checkCancellationIfSupported() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            try Task.checkCancellation()
        }
    }

    static func defaultFetcher(request: URLRequest) async throws -> (Data, URLResponse) {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            return try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let data, let response else {
                        continuation.resume(
                            throwing: CLIDownloadError.responseMissing(request.url ?? URL(fileURLWithPath: "/"))
                        )
                        return
                    }
                    continuation.resume(returning: (data, response))
                }
                task.resume()
            }
        }

        throw CLIDownloadError.requestFailed(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: nil,
            reason: "Async runtime unavailable"
        )
    }
}
