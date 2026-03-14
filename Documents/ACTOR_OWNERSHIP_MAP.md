# Actor Ownership Map

This document tracks mutable runtime ownership boundaries after the `HLS-102` actorization pass.

## Actor-owned runtime components

### `NetworkProxyServerRuntime` (`Sources/HLSCache/ProxyServerRuntime.swift`)

- Type: `actor`
- Ownership scope:
  - listener lifecycle (`listener`, `runningBaseURL`)
  - request handler reference
  - active connection registry (`activeConnections`)
- Concurrency model:
  - state mutation happens through actor isolation
  - socket IO stays on dedicated `ioQueue`
  - callback entrypoints hop into the actor via `Task`

### Active connection registry

- Registry: `[ObjectIdentifier: NWConnection]`
- Owner: `NetworkProxyServerRuntime` actor
- Guarantees:
  - deterministic insert/remove under concurrent connect/disconnect events
  - no external lock/queue required for registry mutation

## Facade boundary

### `HLSCacheFacade` (`Sources/HLSCache/HLSCache.swift`)

- Current synchronization: internal concurrent queue with barrier writes.
- Reason retained:
  - public synchronous APIs (`startServer`, `stopServer`, `proxyStatus`, plugin APIs) remain source-compatible.
- Interaction with actorized runtime:
  - facade delegates proxy listener/connection runtime state to actorized `NetworkProxyServerRuntime`.

## Remaining queue-owned registries (deferred)

- `AliasRegistry` in `CoreCache`
- `BackgroundDownloadTaskRegistry`

These remain queue/barrier synchronized in `1.0.0` for compatibility and staged migration safety. They are candidates for a dedicated follow-up actor migration ticket once fully async call surfaces are available.

## Validation checkpoints

- strict concurrency build gate passes:
  - `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`
- proxy runtime health endpoint validated under concurrent request burst in tests.
