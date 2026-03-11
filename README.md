# SwiftNIO HLS Proxy & Range-Aware Cache

A Swift-based HLS proxy and caching engine designed for AVPlayer. The system provides a local HTTP proxy built on SwiftNIO, a server-agnostic range-aware disk cache, background-capable offline HLS downloading, and a streaming transformation pipeline with optional encrypt-at-rest support.

The architecture cleanly separates playback proxying, storage, and background downloading, allowing reliable foreground streaming while remaining compliant with iOS background execution constraints.

---

## Key Features

- Local HTTP proxy server built with SwiftNIO
- Range-aware disk caching with partial content support (206)
- Optional disk quota with per-asset LRU eviction in `CoreCache`
- Stable alias-based routing (`/MD0534`) and typed proxy resource routes (`/MD0534/seg|key|raw/<encoded-url>`)
- Structured logging hooks across `CoreCache` and `HLSCacheFacade` with log levels and correlation IDs
- Core cache metrics snapshot (hit/miss, bytes served from disk/network, disk/network ratios, disk usage, per-asset completion)
- Background HLS offline downloading via `URLSessionConfiguration.background`
- Streaming transformation plugin pipeline
- Optional encrypt-at-rest layer
- Designed for AVPlayer compatibility (HLS + MP4)
- Server-agnostic `CoreCache` module usable outside proxy context
- Atomic manifest persistence and crash-safe writes
- Thread-safe concurrent read/write support

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

- `206 Partial Content`
- `Content-Range`
- `Accept-Ranges`
- Accurate `Content-Length`

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
If a manifest is corrupted (for example after interruption), it is treated as a cache miss and rebuilt on subsequent writes.

### Alias Registry Persistence

- Alias mappings are persisted at `BaseDirectory/alias_registry.json`.
- Writes are atomic (`alias_registry.json.tmp` + replace), preventing partial JSON files.
- `updateRemoteURL(alias:remoteURL:)` only rotates the remote URL metadata and preserves stable `AssetID`/`CacheKey` identity.
- Registry access is synchronized for safe concurrent reads and mutations.

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
- `EncryptAtRestPlugin(key:)` for reversible at-rest encryption/decryption in streaming mode
- `ByteTransformer` / `ByteStreamTransformer` protocol pair for streaming chunk transforms
- `TransformPipeline` and `TransformPipelineProcessor` for ordered plugin execution without full buffering

Playlist rewrite helper available:
- `HLSPlaylistRewriter.rewrite(_:alias:playlistURL:proxyURLBuilder:)`
  Rewrites segment URIs, `EXT-X-MAP` `URI`, and `EXT-X-KEY` `URI` (except `METHOD=NONE`).
- `HLSPlaylistParser.parse(_:playlistURL:)` to extract media segment and `EXT-X-KEY` remote URLs
- `ProxyRangeResponse.make(rangeHeader:totalLength:)` for AVPlayer-compatible 200/206 range response metadata
- `ProxyCacheCoordinator.serve(...)` for mixed cache/network streaming over `CoreCache` read plans

## CLI Scaffold

A baseline executable target is available for interactive command-line workflows:

```bash
swift run HLSCacheCLI
```

Optional runtime flags:
- `--base-directory <path>`
- `--host <host>`
- `--port <port>`
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
- Press `Enter` to refresh progressively and `q` to return to menu.

Clear cache data from command line (`--yes` is required for non-interactive destructive execution):

```bash
swift run HLSCacheCLI clear --alias MD0534 --yes
swift run HLSCacheCLI clear --alias MD0534 --delete-alias --yes
swift run HLSCacheCLI clear --all --yes
swift run HLSCacheCLI clear --all --delete-alias --yes
```

Export cached HLS media to MP4:

```bash
swift run HLSCacheCLI export --alias MD0534 --output /tmp/MD0534.mp4
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

Export behavior:
- Validates cached media playlist + segment completeness before remux
- Returns actionable error when cache is incomplete
- Uses `ffmpeg` for remux and reports output path + size on success

---

##Design Principles

- No full buffering of large media files
- Correct HTTP Range handling
- Thread-safe concurrent reads and writes
- Atomic manifest updates
- Background-safe downloading
- Remote URL is never identity
- Server-agnostic cache core

##Limitations / Non-Goals

- No DRM system implementation (FairPlay/Widevine)
- No transcoding or re-muxing
- No multi-range HTTP support in initial version
- Live HLS support may be limited in early versions
- Proxy does not remain active while app is suspended
