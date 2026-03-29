# SwiftNIO HLS Proxy & Range-Aware Cache

A Swift-based HLS proxy and caching engine designed for AVPlayer. The system provides a local HTTP proxy built on SwiftNIO, a server-agnostic range-aware disk cache, background-capable offline HLS downloading, and a streaming transformation pipeline with optional encrypt-at-rest support.

The architecture cleanly separates playback proxying, storage, and background downloading, allowing reliable foreground streaming while remaining compliant with iOS background execution constraints.

---

## Key Features

- Local HTTP proxy server built with SwiftNIO
- Range-aware disk caching with partial content support (206)
- Optional disk quota with explicit per-asset eviction recency policy in `CoreCache`
- Stable alias-based routing (`/MD0534`) and typed proxy resource routes (`/MD0534/seg|key|raw/<encoded-url>`)
- Structured logging hooks across `CoreCache` and `HLSCacheFacade` with log levels and correlation IDs
- Core cache metrics snapshot (hit/miss, bytes served from disk/network, disk/network ratios, disk usage, per-asset completion)
- Background HLS offline downloading via `URLSessionConfiguration.background`
- Streaming transformation plugin pipeline
- Optional encrypt-at-rest layer
- Designed for AVPlayer compatibility (HLS + MP4)
- Server-agnostic `CoreCache` module usable outside proxy context
- Offline playback mode toggle in `ProxyCacheCoordinator` (`allowNetworkFallback: false`)
- Async serve API in `ProxyCacheCoordinator` with `NetworkClient` range fetching
- Atomic manifest persistence and crash-safe writes
- Thread-safe concurrent read/write support
- Documented async-first API policy and Swift Concurrency ADR for migration work

### Consumer Logging Protocol

Consumers can inject their own logging implementation without depending on `CoreCache` logging types directly.

```swift
import Foundation
import HLSCache
import OSLog

struct AppHLSLogger: HLSCacheLogConsumer {
    private let logger = Logger(subsystem: "com.example.app", category: "HLSCache")

    func log(_ event: HLSCacheLogEvent) {
        let metadata = String(describing: event.metadata)
        logger.log(
            level: logLevel(event.level),
            "[\(event.operation)] [\(event.correlationID)] \(metadata, privacy: .public)"
        )
    }

    private func logLevel(_ level: HLSCacheLogLevel) -> OSLogType {
        switch level {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        }
    }
}

let facade = HLSCacheFacade(
    baseDirectory: cacheDirectoryURL,
    logConsumer: AppHLSLogger(),
    minimumLogLevel: .debug
)
```

If needed, you can still pass a custom `StructuredLogger` directly via `logger:` for lower-level integration.

### Metrics Semantics

`CoreCacheMetrics` separates planning and serving counters:

- `bytesPlannedFromCache` / `bytesPlannedFromNetwork` reflect `CoreCache.plan(...)` output.
- `bytesServedFromDisk` / `bytesServedFromNetwork` reflect actual bytes emitted at serve boundaries.
- Metrics counters are synchronized on CoreCache's single queue; mutations (`plan`, `recordServedBytes`, write/finalize paths) use barrier writes to avoid lock-order inversions.

This separation highlights divergence cases (for example, planned cache bytes falling back to network due to corrupted/truncated disk payload).

### Eviction Recency Policy

`CoreCache` quota eviction supports explicit recency semantics:

- Default: `leastRecentlyUpdated` (backward compatible). Read traffic does not affect eviction recency.
- Optional: `leastRecentlyAccessed`. Cache-hit reads update recency in `plan(...)`, so read-hot assets are less likely to be evicted.

### Correlation Propagation

- `HLSCacheFacade` continues to generate correlation IDs automatically when callers do not provide context.
- Proxy request handling propagates one correlation ID through facade request logs and downstream `ProxyCacheCoordinator`/`CoreCache` operations for end-to-end traceability.
- `ProxyCacheCoordinator` and key `CoreCache` operations accept optional `correlationID` parameters; omitting them preserves backward-compatible auto-generated IDs.

---

## Architecture Decisions

- [Swift Concurrency and Public API Policy ADR](Documents/ADR/ADR-0001-swift-concurrency-and-api-policy.md)
- [Async API Policy (implementation checklist)](Documents/API_POLICY.md)

All tickets in epic `HLS-98` should reference these documents when introducing async APIs, actor isolation, or sendability changes.

---

## Architecture Overview

```
[ AVPlayer ]
     │ (HTTP requests to localhost)
     ▼
[ ProxyServer (SwiftNIO) ] ──▶ [ TransformPipeline ] ──▶ [ CoreCache ] ──┬──▶ Disk (range-aware)
                                  │                                        └──▶ Network (origin server)
                                  ▼
                             [ HLSModule ]

[ Downloader (background URLSession) ] ──▶ [ CoreCache ] ─▶ Disk
```

### Module Separation

**CoreCache**
- Range index (interval set)
- Manifest persistence
- Disk storage (random access)
- DiskStore seek-based IO for byte-range reads and offset writes
- Read planning (file vs network)
- CoreCache write/finalize pipeline with crash-safe manifest updates
- Concurrency model: single private concurrent queue with barrier writes
- Alias → Asset → CacheKey mapping
- Server-agnostic

**ProxyServer (SwiftNIO)**
- Local HTTP/1.1 server
- GET + Range parsing
- 200 / 206 responses
- Playlist rewriting
- Streams bytes from cache or network

**HLSModule**
- Master/media playlist parsing
- Relative URL resolution
- `EXT-X-KEY` handling
- URI rewriting to proxy routes
- Download planning

**Downloader (Background URLSession)**
- Offline HLS segment/key downloading
- Resume after relaunch
- Persistent task tracking
- Writes into CoreCache storage

**TransformPipeline**
- Streaming middleware applied before caching
- Optional reversible transforms
- Encrypt-at-rest plugin support

---

## Identity Model

The system intentionally separates identity from transport URLs.

###Alias → AssetID → CacheKey → RemoteURL

- **Alias**: Public-facing local route (e.g., `MD0534`)
- **AssetID**: Logical content identifier
- **CacheKey**: Stable hash of AssetID
- **RemoteURL**: Current source URL (may rotate)

Remote URLs are not used as identity because HLS URLs frequently change due to signed tokens, CDN rotation, or backend policy. By decoupling identity from location, cached content remains valid across URL updates.

### Remote URL Rotation Continuity Policy

- Asset continuity is preserved across rotation: `Alias` and `AssetID` keep the same `CacheKey`.
- Resource continuity is strict URL-based for playlist/segment/key/raw bytes: cached bytes are reused only when the canonical resource URL matches.
- Cross-origin/domain URL rotation is treated as a resource miss (new URL => new resource key => fresh fetch), while previously cached bytes remain available for their original URLs until explicit cache clear/eviction.
- `updateRemoteURL` and proxy request logs expose continuity metadata (`rotationPolicy`, host-change signal, and per-request continuity decision) for debugging.

### Planner URL Canonicalization Policy

- Download-planner dedup uses canonical resource identity keys (same policy as `ResourceID.makeResourceKey(from:)`).
- Canonicalization normalizes scheme/host case, default ports, path dot-segments, and query-key ordering.
- Equivalent URL variants dedupe to one planned resource when canonical forms match.
- Policy exception: repeated query-key value order is preserved, so URLs like `?token=a&token=b` and `?token=b&token=a` remain distinct identities.

---

## Playback Flow

1. AVPlayer requests `http://127.0.0.1:<port>/<alias>`.
2. SwiftNIO ProxyServer receives the request.
3. Nested resource requests use route shape:
   - `/<alias>/seg/<encoded-origin-url>`
   - `/<alias>/key/<encoded-origin-url>`
   - `/<alias>/raw/<encoded-origin-url>`
4. Proxy resolves alias → AssetRecord → CacheKey.
5. CoreCache computes a read plan:
   - `.file(range)` for cached bytes
   - `.network(range)` for missing bytes
6. Proxy streams cached bytes directly.
7. Missing ranges are fetched via URLSession and streamed while simultaneously written into cache.
8. Subsequent seeks benefit from cached ranges.

All HTTP responses follow correct Range semantics, including:

- `200 OK` full-content fallback for missing/empty/malformed `Range` headers
- `206 Partial Content`
- `416 Range Not Satisfiable` with `Content-Range: bytes */<totalLength>`
- `Content-Range`
- `Accept-Ranges`
- Accurate `Content-Length`

Offline-mode miss diagnostics are deterministic for machine parsing:

- HTTP `503` body: `offline cache miss`
- Headers: `X-HLSCache-Diagnostic-Schema=1`, `X-HLSCache-Error-Code=offline_cache_miss`,
  `X-HLSCache-Offline-Mode=true`, `X-HLSCache-Missing-Start`, `X-HLSCache-Missing-End-Exclusive`

---

## Offline Download Flow

1. HLSModule parses playlist and resolves all segment and key URLs.
2. Downloader creates background tasks using:
   `URLSessionConfiguration.background(withIdentifier:)`
3. Segment and key files are downloaded even if:
   - App moves to background
   - App is terminated
4. On completion:
   - Files are atomically moved into CoreCache storage
   - Manifest is updated
   - Completed task mapping is removed from persistent task registry
5. On relaunch:
   - Active task mappings are restored from persistent task registry
   - Stale task mappings are pruned
   - Startup reconciliation purges orphan manifests, orphan data files, and orphan `.downloading` staging files

ProxyServer is not required to remain active during background downloading.

---

## Transform Plugin System

The transform pipeline operates in a streaming fashion:

###Network → TransformPipeline → Disk

Plugins can:

- Rewrite playlists
- Compute integrity hashes
- Apply encrypt-at-rest
- Perform content-aware inspection

### Encrypt-at-Rest

Recommended for sensitive content. Stored bytes are encrypted on write and decrypted when served.

`EncryptAtRestPlugin` supports two modes:

- `EncryptAtRestPlugin.Mode.xorInsecure` (default): legacy reversible XOR stream mode for backward compatibility only.
- `EncryptAtRestPlugin.Mode.authenticatedV1`: authenticated mode with keyed stream encryption + RFC 2104 HMAC-SHA256 integrity metadata persisted in cache manifests (`algorithm: hmac-sha256-rfc2104-v1`).
- Invalid key configuration is recoverable: initialization no longer traps, and transform use throws `EncryptAtRestPluginError.invalidKey(...)`.

When authenticated mode is enabled, cached-resource tampering is detected deterministically before serve. On mismatch, cache entries are invalidated and normal network fallback/offline policies apply.

Integrity metadata migration behavior:

- Legacy manifests that store `algorithm: hmac-sha256-v1` are treated as a backward-compatible legacy keyed-SHA256 digest format.
- On successful validation of a complete cached resource, integrity metadata is rewritten to `hmac-sha256-rfc2104-v1` to converge manifests onto the RFC HMAC contract.
- Digest validation uses constant-time comparison for equal-length digests in both RFC and legacy compatibility validation paths.

### Plugin Stamp Migration Policy

Runtime compatibility is evaluated per plugin stamp (`id` + `version`) with this decision matrix:

- Exact same stamp set/order: reuse cached transformed bytes (`exactReuse`).
- Same plugin IDs/order, semantic version upgrade within same major (`1.0.0 -> 1.1.0`): reuse cached bytes (`compatibleReuse`).
- Any plugin count/order/ID change, semantic major change, semantic downgrade, or non-semver version change: invalidate and recache (`forcedRecache`).

Each decision is emitted as a structured log event with `operation=pluginMigrationDecision` for observability.

### AES-128 HLS Caution

If HLS uses `#EXT-X-KEY METHOD=AES-128`, segment data is already encrypted. Arbitrary byte-level transformations on ciphertext will break playback. Prefer wrapping ciphertext with an additional encrypt-at-rest layer rather than modifying HLS-level encryption.

---

## Disk Layout

```
BaseDirectory/
├── alias_registry.json
└── cache/
    └── /<entry>
        └── resources/
            ├── playlistM3U8/
            │   ├── .bin
            │   └── .json
            ├── segment/
            │   ├── .bin
            │   └── .json
            ├── key/
            │   ├── .bin
            │   └── .json
            └── other/
                ├── .bin
                └── .json
```

Each resource has:
- Binary data file
- JSON manifest (ResourceRecord)
  Includes `pluginsApplied` stamps (`id` + `version`) for transform compatibility tracking.

Manifests are written atomically (temp file + replace).
If a manifest decode fails, recovery quarantines it to `*.json.corrupt`, purges the paired `*.bin` data file to avoid invisible/untracked bytes, emits structured diagnostics, and then treats the request as a cache miss for deterministic rebuild.

### Alias Registry Persistence

- Alias mappings are persisted at `BaseDirectory/alias_registry.json`.
- Writes are atomic (`alias_registry.json.tmp` + replace), preventing partial JSON files.
- `updateRemoteURL(alias:remoteURL:)` only rotates the remote URL metadata and preserves stable `AssetID`/`CacheKey` identity.
- Rotation policy is explicit: cache identity stays stable at asset level, while resource-byte reuse remains strict canonical-URL match for playlist/segment/key/raw requests.
- Registry access is synchronized for safe concurrent reads and mutations.

### Background Download Task Registry Persistence

- Background task mappings are persisted at `BaseDirectory/background_download_tasks.json`.
- Writes are atomic (`background_download_tasks.json.tmp` + replace).
- `BackgroundDownloadTaskRegistry.upsert(...)` preserves existing `contentType` and `expectedLength` when incoming values are `nil`.
- Explicit metadata clear is deterministic via `clearContentType` and `clearExpectedLength` flags (clear flags take precedence over provided values).
- On decode corruption/load failures, the registry file is quarantined to timestamped snapshots:
  `background_download_tasks.json.corrupt.<timestamp-ms>-<sequence>`, then reset to an empty JSON mapping so startup can continue deterministically.
- Snapshot retention is bounded deterministically (count-based; oldest snapshots are pruned first).
- Recovery emits structured telemetry with `operation=loadBackgroundDownloadTaskRegistry`, `recoveryAction=quarantine_and_reset`,
  snapshot count metadata, and retention actions (`none` or `pruned_old_snapshots`).
- On non-decode load failures, startup follows the same deterministic quarantine-and-reset policy and emits explicit recovery telemetry (`result=recovered_load_failure`) instead of silently dropping pending task state.

### CLI Settings Persistence

- CLI settings are persisted at `BaseDirectory/cli_settings.json`.
- On corrupted/partial or unreadable settings files, startup quarantines the original file to `cli_settings.json.corrupt` and resets `cli_settings.json` to defaults.
- CLI surfaces explicit recovery diagnostics (result, settings path, recovery path, action, and reason) so settings resets are traceable and actionable.

### Background Recovery Reconciliation Policy

- On startup, recovery reconciles `cache` data files and manifests:
  - Manifest without data file => purge manifest
  - Data file without manifest => purge data file
  - Stale `.downloading` staging file => purge staging file
- Reconciliation emits structured telemetry with `operation=reconcileBackgroundStartup`.
- Summary diagnostics include orphan counts and purged byte totals for deterministic operations visibility.

### Shared Directory Ownership Contract

- `CoreCache` acquires an exclusive advisory lock at `BaseDirectory/.corecache.lock` during initialization.
- If the directory is already owned, initialization fails fast with typed error `CoreCacheDirectoryLockError.directoryInUse`.
- The lock is released on normal deinitialization and is also released by the OS on abnormal process termination.
- Integrators should treat a cache base directory as single-owner at runtime and instantiate one active `CoreCache` per directory.

---

## Usage Example

```swift
import AVFoundation

// Start proxy
let baseURL = try startServer()

// Register asset
try registerAlias(
    alias: "MD0534",
    assetID: "movie_534",
    remoteURL: URL(string: "https://cdn.example.com/video.m3u8")!,
    headers: nil
)

// Get proxy URL
let url = proxyURL(for: "MD0534")

// Play with AVPlayer
let player = AVPlayer(url: url)
player.play()
```

Facade methods now available from `HLSCache`:
- `startServer()` / `stopServer()`
- `register(...)` / `updateRemoteURL(...)`
- `proxyURL(for:)`
- `proxyURL(for:kind:remoteURL:)`
- `decodeProxyRequestURL(_:)`
- `cacheInfo(alias:)` / `listAliases()` / `clearCache(alias:)`
- `removeAlias(alias:)` / `removeAllAliases()`
- `setPlugins(_:)`
- `makeTransformPipeline()`

Baseline plugin available:
- `NoopPlugin(version: "1.0.0")`
- `EncryptAtRestPlugin(key:)` for legacy reversible XOR at-rest encryption/decryption
- `EncryptAtRestPlugin(key:mode: .authenticatedV1)` for authenticated at-rest mode with integrity verification metadata
- `ByteTransformer` / `ByteStreamTransformer` protocol pair for streaming chunk transforms
- `TransformPipeline` and `TransformPipelineProcessor` for ordered plugin execution without full buffering

Playlist rewrite helper available:
- `HLSPlaylistRewriter.rewrite(_:alias:playlistURL:proxyURLBuilder:)`
  Rewrites segment URIs, `EXT-X-MAP` `URI`, and `EXT-X-KEY` `URI` (except `METHOD=NONE`).
- `HLSPlaylistParser.parse(_:playlistURL:)` to extract media segment and `EXT-X-KEY` remote URLs
- `HLSDownloadPlanner.plan(...)` to build full playlist/segment/key/map download plans and produce proxy-rewritten media playlists
- `ProxyRangeResponse.make(rangeHeader:totalLength:)` for AVPlayer-compatible `200`/`206`/`416` range response metadata (`200` fallback on malformed range syntax, `416` on unsatisfiable ranges)
- `ProxyCacheCoordinator.serve(...)` for mixed cache/network streaming over `CoreCache` read plans
  Set `allowNetworkFallback: false` to enforce disk-only serving (offline playback mode).
- Proxy route parsing accepts optional leading path prefixes and resolves routes from the trailing
  `/<alias>/<kind>/<encoded-remote-url>` contract for deployment behind path-based gateways.
- `BackgroundURLSessionDownloadCoordinator` to register URLSession download task mappings, recover active background tasks after relaunch, and finalize completed downloads into cache + manifest atomically.

## CLI Scaffold

A baseline executable target is available for interactive command-line workflows:

```bash
swift run HLSCacheCLI
```

Optional runtime flags:
- `--base-directory <path>`
- `--host <host>`
- `--port <port>`
- `--output-format <text|json>`
- `--help`

Add/register alias mapping from command line:

```bash
swift run HLSCacheCLI add \
  --alias MD0534 \
  --asset-id movie_534 \
  --url "https://cdn.example.com/master.m3u8" \
  --header "Authorization: Bearer <token>"
```

Alias monitor screen (interactive):
- Open `Asset management -> List aliases`.
- Displays alias, assetID, remote URL, cache bytes, and last-updated timestamp.
- If cache metadata lookup fails for an alias, interactive listing stays resilient and emits a degraded record with parseable fields:
  `bytes=(degraded) | cache_status=metadata_error | cache_error=<reason>`.
- Press `Enter` to refresh progressively and `q` to return to menu.

Non-interactive `list` command remains strict:
- Any cache metadata failure returns exit code `1` and reports `Failed to list aliases: ...`.

Non-interactive proxy operations:

```bash
swift run HLSCacheCLI proxy status
swift run HLSCacheCLI proxy restart
swift run HLSCacheCLI --output-format json proxy status
```

Proxy command output contract:
- `proxy status` emits deterministic `proxy.*` fields for automation parsing:
  `proxy.state`, `proxy.host`, `proxy.port`, `proxy.base_url`, `proxy.offline_mode`.
- `proxy.state` reports lifecycle values directly: `starting`, `running`, `stopping`, `stopped`.
- Unavailable runtime fields are explicitly rendered as `unavailable`.
- Exit codes:
  - `0`: success
  - `2`: runtime unavailable (`proxy status`)
  - `3`: restart failure (`proxy restart`)

JSON output mode (`--output-format json`):
- Versioned schema field is always present: `schemaVersion` (current `"1"`).
- `list` JSON payload:
  - `command` = `"list"`
  - `aliases` array items include `alias`, `assetID`, `remoteURL`, `updated`, `cacheBytes`.
- `proxy status` JSON payload:
  - `command` = `"proxy.status"`
  - required fields: `state`, `host`, `port`, `baseURL`, `offlineMode`.
- `proxy restart` JSON payload:
  - `command` = `"proxy.restart"`
  - `result` (`success` or `restart_failure`), `attemptedHost`, `attemptedPort`, `startupError`, and nested `status`.
- When runtime details are unavailable, JSON fields are explicitly set to `"unavailable"` for deterministic key presence.

Clear cache data from command line (`--yes` is required for non-interactive destructive execution):

```bash
swift run HLSCacheCLI clear --alias MD0534 --yes
swift run HLSCacheCLI clear --alias MD0534 --delete-alias --yes
swift run HLSCacheCLI clear --all --yes
swift run HLSCacheCLI clear --all --delete-alias --yes
```

Clear verification output contract:
- `clear` commands now emit deterministic `verify.*` fields for automation parsing.
- Alias scope fields: `verify.scope`, `verify.alias`, `verify.metadata_removed`, `verify.alias_state`, `verify.cache_bytes`, `verify.cache_bytes_status`.
- All scope fields: `verify.scope`, `verify.metadata_removed`, `verify.alias_count_before`, `verify.alias_count_after`, `verify.total_cache_bytes_after`, `verify.total_cache_bytes_status`.
- When alias metadata is intentionally removed, byte fields are explicitly marked as `unavailable` with `*_status=unavailable_metadata_removed`.
- Backward compatibility: existing human-readable summary lines remain, and parse-safe `verify.*` lines are additive.

Export cached HLS media to MP4:

```bash
swift run HLSCacheCLI export --alias MD0534 --output /tmp/MD0534.mp4
swift run HLSCacheCLI export --alias MD0534 --output /tmp/MD0534-av1.mp4 --av1
swift run HLSCacheCLI export --alias MD0534 --output /tmp/MD0534-av1.mp4 --av1 --av1-preset 8 --av1-crf 30 --av1-bitrate 1400k
```

Persisted CLI settings commands:

```bash
swift run HLSCacheCLI settings get
swift run HLSCacheCLI settings set default-user-agent "HLSCacheCLI/1.0"
```

Settings storage:
- Path: `<base-directory>/cli_settings.json`
- Format:

```json
{
  "defaultUserAgent": "HLSCacheCLI/1.0"
}
```

Header precedence for `add`/`register`:
- If `defaultUserAgent` is set and no `User-Agent` header is provided, the default is applied automatically.
- If a per-alias `User-Agent` header is provided, it overrides the global default for that alias.

Interactive cache operations:
- Main menu -> `4) Cache operations`
- `1) Clear cache by alias` or `2) Clear all cache`
- Optional prompt to delete alias metadata
- Destructive confirmation prompt (`--yes`/`yes`) before execution
- Post-clear verification output includes alias state/count and resulting cache bytes

Download behavior:
- Non-interactive `download` shows periodic progress updates.
- Progress lines include processed/known-total resources, elapsed time, ETA, and bytes written.
- Completion prints a final summary including total elapsed time.

Export behavior:
- Validates cached media playlist + segment completeness before remux
- Returns actionable error when cache is incomplete
- Default mode remuxes with `-c copy` for backward compatibility
- Optional `--av1` mode transcodes video with `libsvtav1` (better compression, slower encode)
- AV1 tuning flags: `--av1-preset`, `--av1-crf`, `--av1-bitrate`
- AV1 bitrate format contract: positive integer + suffix `k` or `M` (examples: `1200k`, `2M`)
- Non-interactive `export` shows periodic progress updates with elapsed time and ETA.
- Completion prints a final summary including total elapsed time.
- Uses `ffmpeg` for export and reports output path + size on success

CLI quickstart (add/list/clear/settings/export):

```bash
# 1) Register an alias
swift run HLSCacheCLI add \
  --alias MD0534 \
  --asset-id movie_534 \
  --url "https://cdn.example.com/master.m3u8"

# 2) Open interactive mode to list aliases (press q to return)
swift run HLSCacheCLI
# Main Menu -> 1) Asset management -> 2) List aliases

# 3) Configure default User-Agent
swift run HLSCacheCLI settings set default-user-agent "HLSCacheCLI/1.0"
swift run HLSCacheCLI settings get

# 4) Clear cache safely
swift run HLSCacheCLI clear --alias MD0534 --yes

# 5) Cache full HLS content for offline/export workflows
swift run HLSCacheCLI download --alias MD0534

# 6) Export cached media to MP4
swift run HLSCacheCLI export --alias MD0534 --output /tmp/MD0534.mp4

# 7) Optional AV1 transcode mode (smaller files, slower encode)
swift run HLSCacheCLI export --alias MD0534 --output /tmp/MD0534-av1.mp4 --av1 --av1-preset 8 --av1-crf 30
```

Export prerequisites:
- `ffmpeg` must be installed and available in `PATH`.
- Alias must exist and point to a cached media playlist.
- Required segment data must be fully cached (incomplete cache fails fast).
- AES-128 encrypted playlists are exportable when the referenced key material is already cached.
- Playlists with duplicate segment URIs and `#EXT-X-BYTERANGE` entries are supported; staged segment filenames are generated per occurrence to preserve playback ordering semantics.
- AV1 mode requires an ffmpeg build with `libsvtav1` encoder support.

Export troubleshooting:
- `AV1 argument validation failed`: fix malformed AV1 tuning input (especially `--av1-bitrate` format).
- `ffmpeg is unavailable`: install ffmpeg and verify with `ffmpeg -version`.
- `ffmpeg encoder 'libsvtav1' is not available`: install ffmpeg with AV1 encoder support, or run export without `--av1`.
- `No cached media playlist was found`: ensure the alias was registered and playlist bytes were cached.
- `Cache is incomplete`: warm cache by playing/downloading until required segments are fully written.
- `MP4 remux failed`: inspect playlist/segment integrity and retry export after refreshing cache.

Validation command for local CLI changes:
- `swift test`

---

##Design Principles

- No full buffering of large media files
- Correct HTTP Range handling
- Machine-parseable offline diagnostics (`X-HLSCache-*` response metadata + structured logs)
- Thread-safe concurrent reads and writes
- Atomic manifest updates
- Background-safe downloading
- Remote URL is never identity
- Server-agnostic cache core

##Limitations / Non-Goals

- No DRM system implementation (FairPlay/Widevine)
- No generalized transcoding pipeline outside CLI export mode
- No multi-range HTTP support in initial version
- Live HLS support may be limited in early versions
- Proxy does not remain active while app is suspended
