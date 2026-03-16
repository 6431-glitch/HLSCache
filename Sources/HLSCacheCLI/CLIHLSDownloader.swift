import CoreCache
import Foundation
import HLSCache

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum CLIDownloadError: Error, LocalizedError {
    case aliasNotFound(String)
    case requestFailed(url: URL, statusCode: Int?, reason: String)
    case requestTimedOut(url: URL, timeout: TimeInterval)
    case requestCancelled(url: URL)
    case transportFailure(url: URL, reason: String)
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
        case let .requestTimedOut(url, timeout):
            return "Request timed out after \(timeout)s for \(url.absoluteString)."
        case let .requestCancelled(url):
            return "Request was cancelled for \(url.absoluteString)."
        case let .transportFailure(url, reason):
            return "Transport failed for \(url.absoluteString): \(reason)"
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

struct CLIHLSDownloader {
    typealias Fetcher = (_ request: URLRequest) throws -> (Data, URLResponse)
    typealias CancellationChecker = () -> Bool
    typealias PlanHandler = (_ plan: CLIDownloadPlan) -> Void
    typealias ProgressHandler = (_ progress: CLIDownloadProgress) -> Void

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

    private final class FetchResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private let condition = NSCondition()
        private var data: Data?
        private var response: URLResponse?
        private var error: Error?
        private var completed = false

        func complete(data: Data?, response: URLResponse?, error: Error?) {
            lock.lock()
            self.data = data
            self.response = response
            self.error = error
            self.completed = true
            lock.unlock()
            condition.lock()
            condition.broadcast()
            condition.unlock()
        }

        func wait(until deadline: Date) -> Bool {
            condition.lock()
            defer { condition.unlock() }

            while true {
                lock.lock()
                let isCompleted = completed
                lock.unlock()

                if isCompleted {
                    return true
                }
                if !condition.wait(until: deadline) {
                    return false
                }
            }
        }

        func snapshot() -> (data: Data?, response: URLResponse?, error: Error?, completed: Bool) {
            lock.lock()
            let snapshot = (data: data, response: response, error: error, completed: completed)
            lock.unlock()
            return snapshot
        }
    }

    private let baseDirectory: URL
    private let facade: HLSCacheFacade
    private let diskStore: DiskStore
    private let manifestStore: ManifestStore
    private let requestTimeout: TimeInterval
    private let cancellationChecker: CancellationChecker
    private let fetcher: Fetcher

    init(
        baseDirectory: URL,
        facade: HLSCacheFacade,
        diskStore: DiskStore? = nil,
        manifestStore: ManifestStore? = nil,
        requestTimeout: TimeInterval = 30,
        cancellationChecker: @escaping CancellationChecker = { false },
        fetcher: Fetcher? = nil
    ) {
        self.baseDirectory = baseDirectory
        self.facade = facade
        self.diskStore = diskStore ?? DiskStore(baseDirectory: baseDirectory)
        self.manifestStore = manifestStore ?? ManifestStore(baseDirectory: baseDirectory)
        self.requestTimeout = max(requestTimeout, 0.001)
        self.cancellationChecker = cancellationChecker
        self.fetcher = fetcher ?? Self.makeDefaultFetcher(cancellationChecker: cancellationChecker)
    }

    func download(
        alias: String,
        planHandler: PlanHandler? = nil,
        progressHandler: ProgressHandler? = nil
    ) throws -> CLIDownloadResult {
        guard let asset = facade.listAliases().first(where: { $0.alias == alias }) else {
            throw CLIDownloadError.aliasNotFound(alias)
        }

        try ensureNotCancelled(for: asset.currentRemoteURL)
        let plan = try buildDiscoveryPlan(rootURL: asset.currentRemoteURL, headers: asset.headers)

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
            try ensureNotCancelled(for: playlistURL)
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
            let fetchedKey = try fetchResource(url: keyURL, headers: asset.headers)
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
            let fetchedSegment = try fetchResource(url: segmentURL, headers: asset.headers)
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

    private func buildDiscoveryPlan(rootURL: URL, headers: [String: String]?) throws -> DiscoveryPlan {
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
            let playlistURL = pendingPlaylists.removeFirst()
            try ensureNotCancelled(for: playlistURL)
            let playlistKey = canonicalURLKey(for: playlistURL)
            guard visitedPlaylists.insert(playlistKey).inserted else {
                continue
            }

            let fetchedPlaylist = try fetchResource(url: playlistURL, headers: headers)
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

    private func fetchResource(url: URL, headers: [String: String]?) throws -> FetchedResource {
        try ensureNotCancelled(for: url)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        for (name, value) in (headers ?? [:]) {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try fetcher(request)
        } catch let error as CLIDownloadError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw CLIDownloadError.requestTimedOut(url: url, timeout: requestTimeout)
            case .cancelled:
                throw CLIDownloadError.requestCancelled(url: url)
            default:
                throw CLIDownloadError.transportFailure(url: url, reason: error.localizedDescription)
            }
        } catch {
            throw CLIDownloadError.transportFailure(url: url, reason: error.localizedDescription)
        }

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
        let attributes: [HLSDirectiveAttribute]
        do {
            attributes = try HLSDirectiveAttributeParser.parseAfterDirectiveNameStrict(in: line)
        } catch {
            throw CLIDownloadError.requestFailed(
                url: baseURL,
                statusCode: nil,
                reason: "Invalid URI attribute in line: \(line)"
            )
        }
        guard let raw = attributes.first(where: { $0.key == "URI" })?.value else {
            return nil
        }
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

    private func looksLikePlaylistURL(_ url: URL) -> Bool {
        let absolute = url.absoluteString.lowercased()
        return absolute.contains(".m3u8")
    }

    private func looksLikePlaylistPath(_ raw: String) -> Bool {
        raw.lowercased().contains(".m3u8")
    }

    static func defaultFetcher(request: URLRequest) throws -> (Data, URLResponse) {
        try makeDefaultFetcher(cancellationChecker: { false })(request)
    }

    private func ensureNotCancelled(for url: URL) throws {
        if cancellationChecker() {
            throw CLIDownloadError.requestCancelled(url: url)
        }
    }

    private static func makeDefaultFetcher(cancellationChecker: @escaping CancellationChecker) -> Fetcher {
        { request in
            let box = FetchResultBox()
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                box.complete(data: data, response: response, error: error)
            }
            task.resume()

            let timeout = max(request.timeoutInterval, 0.001)
            let startedAt = Date()
            let pollInterval: TimeInterval = 0.05

            while true {
                if cancellationChecker() {
                    task.cancel()
                    throw URLError(.cancelled)
                }

                let elapsed = Date().timeIntervalSince(startedAt)
                if elapsed >= timeout {
                    task.cancel()
                    throw URLError(.timedOut)
                }

                let remaining = timeout - elapsed
                let waitWindow = min(pollInterval, remaining)
                let deadline = Date().addingTimeInterval(waitWindow)
                if box.wait(until: deadline) {
                    break
                }
            }

            let snapshot = box.snapshot()
            if let error = snapshot.error {
                throw error
            }
            guard let data = snapshot.data, let response = snapshot.response else {
                throw CLIDownloadError.responseMissing(request.url ?? URL(fileURLWithPath: "/"))
            }
            return (data, response)
        }
    }
}
