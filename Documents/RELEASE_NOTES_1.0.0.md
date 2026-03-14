# Release Notes 1.0.0

## Async migration highlights

- Added unified async `ProgressEvent` streams for download/export/clear workflows.
- Added legacy closure compatibility wrappers with deprecation annotations to support staged migration.
- Expanded sendability audit and rationale coverage across concurrency-sensitive modules.
- Actorized proxy runtime listener/connection state ownership and published actor ownership map.

## Consumer action required

Integrators should migrate from legacy closure wrappers to async stream APIs.

Primary migration reference:

- [Async/Actor Consumer Migration Guide](ASYNC_ACTOR_MIGRATION_GUIDE.md)
- [Actor Ownership Map](ACTOR_OWNERSHIP_MAP.md)

## Deprecation policy

- Legacy wrappers remain available in `1.x` for migration.
- Wrapper removal is planned for the next major version after migration window completion.
