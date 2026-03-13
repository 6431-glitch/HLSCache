# Sendable Audit (HLS-103)

## Summary

- Baseline `@unchecked Sendable` count: **20**
- Current `@unchecked Sendable` count: **17**
- Removed `@unchecked Sendable`:
- `TransformPipeline` (`Sources/HLSCache/TransformPipeline.swift`)
- `TransformPipelineProcessor` (`Sources/HLSCache/TransformPipeline.swift`)
- `URLSessionNetworkClient` (`Sources/HLSCache/NetworkClient.swift`)

## Retained `@unchecked Sendable` and rationale

- `AliasRegistry`: queue-guarded mutable dictionary + atomic file persistence
- `CoreCache`: queue/lock coordinated cache/metrics mutation
- `DirectoryLock`: OS file lock lifecycle + process reservation lock
- `DiskStore`: queue-serialized file mutations
- `ManifestStore`: queue-serialized manifest reads/writes
- `BackgroundDownloadTaskRegistry`: queue/barrier serialized task map + persistence
- `BackgroundDownloadRecoveryCoordinator`: barrier queue around recovery write path
- `BackgroundURLSessionDownloadCoordinator`: delegates mutable coordination to recovery coordinator
- `XORCipherStreamTransformer`: mutable stream offset protected by `NSLock`
- `HLSCacheFacade`: queue-guarded runtime state (`serverBaseURL`, `runtimeState`, plugins)
- `ProxyCacheCoordinator`: queue-coordinated shared streaming/cache state
- `ProxyServerRuntime`: serial queue around runtime lifecycle
- `NetworkProxyServerRuntime`: queue-guarded listener/socket mutable state
- `StartupBox`: `NSLock`-guarded startup result handoff
- `CLIAsyncResultBox`: lock + semaphore result bridge
- `DownloadCommandState`: lock-guarded progress state shared across callbacks
- `CLIHLSDownloader`: stores non-Sendable facade/cache handles; usage constrained to synchronized APIs

## Strict concurrency compile check

Run:

```bash
swift build -Xswiftc -strict-concurrency=complete
```

If this fails in downstream environments, treat failures as compatibility exceptions and document each exception before adding new `@unchecked Sendable`.
