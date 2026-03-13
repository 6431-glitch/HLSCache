# Progress Event Model (HLS-105)

`ProgressEvent` is a shared, `Sendable` progress payload for async operation streams.

## Event shape

- `operation`: `download | export | clear`
- `state`: `started | running | completed | failed | cancelled`
- `processedUnits`: completed work units
- `totalUnits`: planned work units
- `bytesWritten`: optional byte counter when applicable
- `detail`: human-readable context for UI/CLI rendering

## Async streams exposed

- `CLIHLSDownloader.downloadProgressEvents(alias:)`
- `CLIExporter.exportProgressEvents(alias:outputURL:videoCodec:)`
- `HLSCacheFacade.clearCacheProgressEvents(alias:)`
- module-level helper: `clearCacheProgressEvents(alias:)`

## Semantics

- Every stream emits `started` first.
- `running` events are emitted as progress updates become available.
- On success, stream emits `completed` and finishes normally.
- On failure, stream emits `failed` and finishes by throwing.
- On cancellation, stream emits `cancelled` and finishes by throwing `CancellationError`.
