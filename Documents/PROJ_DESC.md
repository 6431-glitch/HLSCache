# SwiftNIO HLS Proxy & Cache Engine — Project Specification

## Objective

Build a Swift package that provides:

- Local HTTP proxy server using SwiftNIO
- Byte-range aware caching
- HLS support (playlist, segments, key handling)
- Stable local alias URLs (e.g. /MD0534)
- Background-capable offline HLS downloading (URLSession background)
- Streaming transformation plugin system
- Encrypt-at-rest support (optional)
- PiP-compatible playback (but not dependent on it)

---

# Architecture Overview

## Layered Modules

### 1) CoreCache
Responsible for:
- CacheKey generation
- Alias → Asset → CacheKey mapping
- Range index (interval set)
- Disk storage (data + manifest)
- Range planning (file + network mixing)
- Streaming read/write abstraction

Must be server-agnostic.

---

### 2) ProxyServer (SwiftNIO)
Local HTTP/1.1 server bound to 127.0.0.1.

Responsibilities:
- Parse GET requests
- Parse Range headers
- Route by alias
- Return correct 200 / 206 responses
- Stream cached/network bytes to client
- Rewrite HLS playlists
- Forward required headers

Pipeline:
- HTTPServerCodec
- HTTPObjectAggregator (optional)
- ProxyRequestHandler

Must not buffer entire segments.

---

### 3) HLSModule
Responsibilities:
- Parse master and media playlists
- Resolve relative segment URLs
- Detect EXT-X-KEY
- Rewrite playlist URLs to proxy routes
- Support remote URL rotation
- Generate download plans

---

### 4) Downloader (Background URLSession)
Responsible for:
- Offline HLS download
- Segment + key downloads
- Persist download progress
- Resume after relaunch
- Move completed files into cache store
- Update manifest

Must use:
URLSessionConfiguration.background(withIdentifier:)

Proxy must NOT depend on being alive for background downloading.

---

### 5) TransformPipeline
Streaming plugin middleware for resources before caching.

Supported resource types:
- playlist
- segment
- key
- other

Must:
- Operate streaming (no full-buffer transforms)
- Record plugin IDs in manifest
- Optionally support reversible transforms

Recommended plugins:
- PlaylistRewritePlugin
- EncryptAtRestPlugin
- SHA256IntegrityPlugin
- NoopPlugin

WARNING:
Do NOT modify AES-128 encrypted HLS ciphertext unless fully re-encrypting correctly.
Prefer encrypt-at-rest layer.

---

# Identity Model

Never use remote URL as identity.

Hierarchy:

Alias (MD0534)
    ↓
AssetID (logical ID)
    ↓
CacheKey (hash of AssetID)
    ↓
RemoteURL (mutable)

Alias remains stable.
RemoteURL may rotate.

---

# Proxy URL Structure

Base:
http://127.0.0.1:<port>/<alias>

Routing:

GET /MD0534
    → return rewritten playlist or root resource

GET /MD0534/seg/<encoded>
    → segment request

GET /MD0534/key/<encoded>
    → key request

GET /MD0534/raw/<encoded>
    → generic passthrough

Encoded should be base64url or percent-encoded original URL.

All playlist internal URLs MUST be rewritten to proxy routes.

---

# HTTP Requirements (AVPlayer Compatible)

Must support:
- GET
- Single Range requests

For Range:
- Status 206
- Content-Range
- Accept-Ranges: bytes
- Content-Length
- Correct Content-Type

For full:
- Status 200
- Content-Length

Must stream responses respecting backpressure.

---

# Background Download Strategy (Approach A)

Proxy runs only when app active.

Offline downloads handled by background URLSession:

- Parse HLS
- Generate segment + key list
- Create background tasks
- Persist mapping: taskID → (alias, resourceKey)
- On completion:
    - Move temp file to cache store
    - Update manifest
    - Mark segment complete

Must handle:
- App relaunch
- Resume downloads
- Network constraints
- Wi-Fi-only option

Optional:
- BGTaskScheduler to resume stalled downloads

---

# PiP Behavior

If PiP playback is active:
- SwiftNIO proxy may continue serving
- Not guaranteed indefinitely

Design must NOT rely on proxy running in background.

---

# CoreCache Requirements

- Persistent manifest per asset
- Interval-based range index
- Atomic writes
- Crash recovery safe
- Streaming read API
- Mixed file/network range planner

---

# Milestones

## Milestone 1
Implement CoreCache + tests.

## Milestone 2
SwiftNIO server serving static content.

## Milestone 3
MP4 playback through proxy with range caching.

## Milestone 4
HLS playback with playlist rewrite.

## Milestone 5
Alias registry + remote URL rotation.

## Milestone 6
Background HLS offline download.

## Milestone 7
Transform pipeline integration.

---

# Public API Draft

startServer()
stopServer()

register(alias:assetID:remoteURL:headers:)
updateRemoteURL(alias:remoteURL:)

proxyURL(for:)

preload(alias:)
downloadForOffline(alias:)
offlineStatus(alias:)

cacheInfo(alias:)
clearCache(alias:)

setPlugins([...])

---

# Non-Functional Requirements

- No full buffering of large segments
- Explicit threading model
- Structured logging
- Cache hit/miss metrics
- Disk limit and eviction policy

---

# Success Criteria

- Stable alias URL works regardless of remote URL rotation
- HLS plays through localhost
- Background downloads complete even if app terminated
- Cached segments replay instantly
- Transform plugins work without breaking playback
