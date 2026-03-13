# Compatibility Wrappers and Deprecation Plan (HLS-106)

This document defines the migration path from closure-style compatibility APIs to async stream APIs.

## Compatibility wrappers (legacy)

Deprecated wrappers retained for migration:

- `CLIHLSDownloader.downloadLegacy(alias:planHandler:progressHandler:completion:)`
- `CLIExporter.exportLegacy(alias:outputURL:videoCodec:progressHandler:completion:)`
- `HLSCacheFacade.clearCacheLegacy(alias:progressHandler:completion:)`
- module helper: `clearCacheLegacy(alias:progressHandler:completion:)`

Each wrapper delegates to async operations while preserving callback-based call sites.

## Preferred async APIs

- `CLIHLSDownloader.downloadProgressEvents(alias:)`
- `CLIExporter.exportProgressEvents(alias:outputURL:videoCodec:)`
- `HLSCacheFacade.clearCacheProgressEvents(alias:)`
- module helper: `clearCacheProgressEvents(alias:)`

## Migration examples

Before (legacy callback wrapper):

```swift
downloader.downloadLegacy(
    alias: "MD001",
    planHandler: { plan in print(plan.totalUnits) },
    progressHandler: { progress in print(progress.processedUnits) },
    completion: { result in print(result) }
)
```

After (async stream):

```swift
for try await event in downloader.downloadProgressEvents(alias: "MD001") {
    print(event.state, event.processedUnits, event.totalUnits)
}
```

Before (legacy clear wrapper):

```swift
facade.clearCacheLegacy(
    alias: "MD001",
    progressHandler: { event in print(event.state) },
    completion: { result in print(result) }
)
```

After (async stream):

```swift
for try await event in facade.clearCacheProgressEvents(alias: "MD001") {
    print(event.state)
}
```

## Deprecation timeline

1. Current release: wrappers remain available and deprecated with migration messages.
2. Next minor release: keep wrappers, update all internal call sites to async streams.
3. Next major release: remove deprecated wrappers after downstream migration window.
