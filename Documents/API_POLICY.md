# HLSCache Async API Policy

Last updated: 2026-03-13  
Source of truth: `Documents/ADR/ADR-0001-swift-concurrency-and-api-policy.md`

## Policy goals

- Make async APIs the default for IO and coordination paths.
- Keep compatibility for existing adopters without duplicating logic.
- Standardize actor ownership and sendability expectations.

## Rules for new or changed APIs

1. Prefer `async`/`throws` as the primary public surface.
2. Keep closure APIs as wrappers only, with clear migration guidance.
3. Avoid creating new mutable shared state outside actor/owned synchronization boundaries.
4. Require `Sendable` for values that cross concurrency domains.
5. Treat `@unchecked Sendable` as an exception with documented invariants and a removal plan.

## Wrapper template expectations

- Async implementation owns behavior.
- Wrapper performs argument conversion and invokes async implementation in a `Task`.
- Wrapper returns results/errors without changing semantics.
- Wrapper docs must reference the async replacement.

## Actor ownership map (working target)

- `HLSCacheFacade`: top-level orchestration ownership.
- `ProxyCacheCoordinator`: serve path and request lifecycle ownership.
- `BackgroundDownloadTaskRegistry` and `BackgroundDownloadRecoveryCoordinator`: download task state ownership.
- `CoreCache` family (`CoreCache`, `AliasRegistry`, `ManifestStore`, `DiskStore`): storage and identity ownership.

## Review checklist for pull requests

- Does the API provide an async-first entry point?
- If a closure wrapper exists, is it thin and documented as compatibility?
- Are mutable shared states isolated by actor or existing synchronization boundary?
- Are `Sendable` conformances explicit and justified?
- If `@unchecked Sendable` is used, are invariants and follow-up tasks documented?

