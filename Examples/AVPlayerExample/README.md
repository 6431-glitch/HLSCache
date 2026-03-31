# AVPlayer UIKit Example

A minimal iOS UIKit example app that plays an HLS stream through `HLSCache` with an inline `AVPlayer` surface.

## Generate project

```bash
cd Examples/AVPlayerExample
xcodegen generate
```

## Open

```bash
open AVPlayerExample.xcodeproj
```

## Run

1. Select an iOS Simulator.
2. Build and run the `AVPlayerExample` scheme.
3. Enter any playlist URL (or keep the default demo URL).
4. Tap **Play Demo Stream**.
5. Shake the device/simulator to open PulseUI logs.

The app initializes `HLSCacheFacade` with a `GetNetworkClient`, routes Get through Pulse, and displays logs in PulseUI.
