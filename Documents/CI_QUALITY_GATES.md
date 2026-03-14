# CI Quality Gates

This document defines the concurrency-focused CI gates for `HLS-108`.

## Gate lanes

- `build`: baseline `swift build` + `swift test`
- `strict-concurrency`:
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`
- `swift test -Xswiftc -strict-concurrency=complete`
- `tsan`:
- `swift test --sanitize=thread`

## Scope

- Strict-concurrency lane targets compile-time concurrency correctness and sendability hygiene.
- TSAN lane targets runtime race detection on core concurrent code paths (`CoreCache`, proxy serving, downloader/recovery, CLI async flows).

## Failure behavior

- Any failing lane fails the PR check.
- Strict-concurrency build treats warnings as errors to block regressions in primary targets.
- TSAN failures are treated as release blockers for migrated concurrency code.

## Remediation flow

1. Identify failing lane (`strict-concurrency` or `tsan`).
2. Reproduce locally with the same command from the CI log.
3. Fix the underlying concurrency issue (sendability, actor isolation, shared mutable state, or race).
4. Add/adjust tests for the reproduced condition.
5. Re-run full CI lanes before requesting review.
