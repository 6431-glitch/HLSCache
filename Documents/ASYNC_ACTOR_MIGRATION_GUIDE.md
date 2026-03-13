# Async/Actor Migration Guide for Consumers

This guide helps existing integrators migrate from callback-style usage to async event streams introduced during the `HLS-98` migration.

## What changed

- Async progress is now exposed through `AsyncSequence` streams (`ProgressEvent`).
- Legacy closure wrappers remain available for migration safety but are deprecated.
- Concurrency-sensitive internals are increasingly isolated and sendability-audited.

## API migration quick map

- Download:
- From: `downloadLegacy(alias:planHandler:progressHandler:completion:)`
- To: `downloadProgressEvents(alias:)`
- Export:
- From: `exportLegacy(alias:outputURL:videoCodec:progressHandler:completion:)`
- To: `exportProgressEvents(alias:outputURL:videoCodec:)`
- Clear:
- From: `clearCacheLegacy(alias:progressHandler:completion:)`
- To: `clearCacheProgressEvents(alias:)`

## Before/after examples

Before (download legacy wrapper):

```swift
downloader.downloadLegacy(
    alias: "MD001",
    planHandler: { plan in print("planned:", plan.totalUnits) },
    progressHandler: { progress in print("done:", progress.processedUnits) },
    completion: { result in print(result) }
)
```

After (download async stream):

```swift
for try await event in downloader.downloadProgressEvents(alias: "MD001") {
    print(event.state.rawValue, event.processedUnits, "/", event.totalUnits)
}
```

Before (clear legacy wrapper):

```swift
facade.clearCacheLegacy(
    alias: "MD001",
    progressHandler: { event in print(event.state.rawValue) },
    completion: { result in print(result) }
)
```

After (clear async stream):

```swift
for try await event in facade.clearCacheProgressEvents(alias: "MD001") {
    print(event.state.rawValue, event.detail ?? "")
}
```

## Actor-isolation expectations

- Avoid sharing mutable reference types across concurrent tasks without synchronization.
- Treat callback invocations as potentially concurrent unless API contract states otherwise.
- Prefer immutable value snapshots (`struct`) for UI/state propagation.
- Avoid blocking calls (semaphores/locks) inside async contexts unless strictly bounded and reviewed.

## Common migration pitfalls

- Consuming stream events on detached tasks without cancellation propagation.
- Ignoring `.failed` and `.cancelled` states and only handling `.completed`.
- Mixing legacy and async APIs in the same flow, causing duplicated progress reporting.
- Assuming progress totals are known before the first planning/running event.

## Custom network client adapter guidance

Use `NetworkClient` for custom transport integrations:

```swift
@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
struct MyNetworkClient: NetworkClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        // Replace with custom stack (e.g. authenticated gateway, custom retry, tracing)
        return try await URLSession.shared.data(for: request)
    }
}
```

Recommendations:

- Preserve HTTP status and headers needed for range/content-length semantics.
- Keep adapter `Sendable` and avoid mutable global state.
- Bubble transport errors without rewriting to opaque generic failures.

## Rollout guidance

1. Migrate new code paths to async stream APIs first.
2. Keep legacy wrappers only at boundaries that cannot migrate immediately.
3. Remove wrapper usage incrementally and monitor deprecation warnings.
4. Plan final wrapper removal for the next major release window.
