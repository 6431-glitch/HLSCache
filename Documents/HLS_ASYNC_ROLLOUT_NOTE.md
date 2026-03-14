# HLS Async Rollout Note

## Milestone

- Milestone ticket: `HLS-109`
- Epic: `HLS-98` (HLS Async)
- Date: 2026-03-14

## Completion summary

The HLS async migration scope is complete across all planned workstreams:

- ADR and API policy published (`HLS-99`)
- async network abstraction completed (`HLS-100`)
- async proxy serve path completed (`HLS-101`)
- runtime actorization completed (`HLS-102`)
- sendability audit completed (`HLS-103`)
- CLI async migration completed (`HLS-104`)
- unified progress-event model completed (`HLS-105`)
- compatibility wrappers + deprecation plan completed (`HLS-106`)
- migration guide completed (`HLS-107`)
- strict-concurrency + TSAN CI gates completed (`HLS-108`)

## Release-readiness checks

- strict concurrency build gate is enabled and passing
- proxy runtime concurrent request stress coverage is in place
- migration and ownership docs are published:
  - `ASYNC_ACTOR_MIGRATION_GUIDE.md`
  - `ACTOR_OWNERSHIP_MAP.md`
  - `COMPATIBILITY_DEPRECATION_PLAN.md`
  - `CI_QUALITY_GATES.md`

## Residual risk

- Full actorization of legacy queue-backed registries (`AliasRegistry`, `BackgroundDownloadTaskRegistry`) is intentionally deferred to a dedicated follow-up once fully async call surfaces are introduced.
- This does not block 1.0.0 release readiness for the HLS async milestone; current behavior remains backward compatible and validated.
