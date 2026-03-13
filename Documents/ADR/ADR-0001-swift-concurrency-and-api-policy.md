# ADR-0001: Swift Concurrency and Public API Policy

- Status: Accepted
- Date: 2026-03-13
- Epic: HLS-98
- Related tickets: HLS-99, HLS-100, HLS-101, HLS-102, HLS-103, HLS-104, HLS-105, HLS-106, HLS-107, HLS-108, HLS-109

## Context

HLSCache currently combines synchronous internals, callback-style APIs, private queue isolation, and selective `@unchecked Sendable` usage.
The epic `HLS-98` migrates the package to Swift Concurrency (`async/await`, actors, and strict sendability) without breaking adopters that still rely on closure-based integrations.

We need one stable decision record that defines:

- Async-first API design rules
- Actor ownership boundaries for mutable runtime state
- `Sendable` and `@unchecked Sendable` usage constraints
- Closure compatibility and deprecation policy

## Decision

### 1) Async-first public API

- New public APIs in `HLSCache` and `CoreCache` must be `async` primary when they involve IO, coordination, or potentially blocking work.
- Existing closure-based APIs are compatibility wrappers only and must forward to async implementations.
- Async APIs are the only source of business logic. Wrappers must stay thin and non-duplicative.

### 2) Closure usage policy

- Closures are allowed for:
  - Interop with platform/delegate callbacks (`URLSession`, NIO handlers)
  - Backward-compatible wrappers during migration
  - Streaming callbacks where `AsyncSequence` is not yet practical
- Closures are not allowed as the primary surface for new long-running operations.
- Any new closure API must include a migration path to `async` and a deprecation note once async parity exists.

### 3) Actor boundary map

- `HLSCacheFacade`: API entry boundary; target actor-owned facade state.
- `ProxyCacheCoordinator`: request/stream orchestration boundary; target actor isolation for mutable request state.
- `BackgroundDownloadTaskRegistry` and `BackgroundDownloadRecoveryCoordinator`: task bookkeeping boundary; migrate to actor-backed state management.
- `CoreCache`, `AliasRegistry`, `ManifestStore`, and `DiskStore`: storage/identity boundary; move from queue+lock model to explicit actor ownership where feasible.

Until each module is actorized, existing queue/lock guards remain authoritative synchronization and must not be bypassed.

### 4) Sendable policy

- Public value types crossing task boundaries must conform to `Sendable`.
- Reference types should prefer actor isolation over `@unchecked Sendable`.
- `@unchecked Sendable` is temporary and requires:
  - Explicit invariant comment describing synchronization strategy
  - Test coverage for concurrent access behavior
  - Tracking task to remove or narrow the unchecked boundary

### 5) Migration strategy

- Implement async-first APIs incrementally by subsystem (networking, serve path, state ownership, CLI adapters).
- Preserve source compatibility with thin wrappers during rollout.
- Mark wrappers for deprecation after one stable release with async alternatives.
- Gate completion with strict concurrency and TSAN checks (`HLS-108`).

## Consequences

- Better correctness under concurrency and clearer ownership boundaries.
- Temporary dual API surfaces during migration.
- Moderate short-term overhead to maintain wrappers and migration docs.
- Reduced long-term maintenance by converging on a single async-first model.

