<p align="center"><img src="assets/fuji-stamp.png" alt="Fuji Kit" width="220"></p>

# Fuji Kit

Fuji Kit connects Fujifilm cameras to an iOS app and provides a Swift SDK for building your own tools.

- **Use the app:** Pair your camera, connect to its Wi-Fi, and save JPEG and RAW photos to Photos.
- **Build with the SDK:** [Add FujiKit to your Swift package](#fujikit-swift-library).
- **Try without a camera:** [Run the simulator](#try-it-without-a-camera).

The app connection flow has been tested with the X-T30 III. Other models may behave differently; see [Status](#status).

## iOS app

### Install and connect on iOS

You need Xcode and an iPhone running iOS 17 or later.

1. Open [App/FujiXOpen.xcodeproj](App/FujiXOpen.xcodeproj) in Xcode. Under **Signing & Capabilities**, select your team. A free **Personal Team** works for the default build; use a unique bundle identifier if needed.
2. Select the **FujiXOpen** scheme and your iPhone, then click **Run**.
3. On the X-T30 III (or other newer models that use Fuji X app), turn Airplane Mode off and Bluetooth on in **MENU/OK → Network/USB Setting**. From the shooting display, choose **DISP/BACK → Bluetooth → PAIRING**.
4. In the app, tap **Pair a camera**, select the camera, and confirm matching codes if prompted. Keep the camera awake on the shooting display while the app starts Wi-Fi.
5. Join the network shown in **Join camera Wi-Fi** using **Settings → Wi-Fi**. Return to the app and tap **I’ve joined** if the gallery hasn’t opened.

### Save photos

In **Photos**, tap a thumbnail or filename to preview it, then tap **Save photo**. To save several, select the circles beside unsaved photos and tap **Save to Photos**. RAW previews use the camera’s thumbnail when available.

### Reconnect

To reconnect to a saved camera, tap **Connect to [camera name]**. If you’re already on Wi-Fi started by the Bluetooth handoff, use **Connection options (…) → Open gallery on camera Wi-Fi**.

Automatic Wi-Fi joining is off by default; to opt in, sign with a paid Apple Developer Program team and set `HOTSPOT_AUTOJOIN = YES` in [App/FujiXOpen.xcconfig](App/FujiXOpen.xcconfig).

## FujiKit Swift library

Build your own Fujifilm tools with FujiKit on iOS 16+, macOS 13+, or Linux. It provides Wi-Fi camera discovery, PTP/IP sessions, device and storage info, gallery listing, thumbnail retrieval on cameras that support it, and streamed file downloads, with no external dependencies.

Add the dependency in `Package.swift` and add the product to your target’s dependencies:

```swift
// Package dependencies:
.package(url: "https://github.com/atomiczsec/fuji-x-open-kit.git", branch: "main")
// Target dependencies:
.product(name: "FujiKit", package: "fuji-x-open-kit")
```

Once your device is on the camera’s Wi-Fi, stream the first object into your own async sink:

```swift
import Foundation
import FujiKit

func downloadFirstPhoto(host: String, sink: @escaping @Sendable (Data) async throws -> Void) async throws {
    let camera = try await CameraSession.connect(host: host)
    do {
        if let handle = try await camera.getObjectHandles().first {
            try await camera.getObject(handle, sink: sink)
        }
    } catch {
        try? await camera.close()
        throw error
    }
    try await camera.close()
}
```

For Bluetooth image browsing, supply your platform’s `GATTPeripheral` to `FujiBLEDriver` for pairing and call `handoff(function: .imageBrowsing)` to start the camera’s Wi-Fi and get its network details. After joining, connect with `CameraSession.connect(host:mode:)` using `.bluetoothXApp`.

## Status

The iOS connection flow has been tested on the Fujifilm X-T30 III, but the project is not hardware-certified and other models may behave differently. Live view and remote capture are out of scope. RAW import depends on iOS support and hasn’t been verified with real RAF files.

## Development

Build and test the library:

```sh
swift build
swift test
xcodebuild -project App/FujiXOpen.xcodeproj -scheme FujiXOpen -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Run the Xcode command on macOS; substitute an installed simulator if needed.

### Try it without a camera

```sh
swift run fujictl simulate --objects ~/Pictures/FujiDemo
```

Use a directory with real JPEG files to try importing into Photos. In the iOS Simulator, open **Connection options (…) → Connect manually over Wi-Fi**, enter host `127.0.0.1` and port `55740`, then tap **Find camera** and select the result.

Or leave the server running and try the CLI from another terminal:

```sh
swift run fujictl info --host 127.0.0.1
swift run fujictl list --host 127.0.0.1
swift run fujictl get 1 --host 127.0.0.1 --output demo.jpg
```

Use a JPEG handle printed by `list` in place of `1` if needed. For hardware, join the camera Wi-Fi and pass its IP as `--host`; add `--xapp` if the network was started for Bluetooth image browsing.


## License

Fuji Kit is released under the [MIT License](LICENSE) (Copyright 2026 Gavin Kramer). See [NOTICE](NOTICE) for third-party attributions.

## Credits

Substantial protocol logic in FujiKit (handshake, Wireless Communication setup, XApp gallery sequence, AutoSave discovery parsing, BLE UUID tables) was derived from [libfuji](https://github.com/petabyt/libfuji/tree/04761bd602617b32b58faa7ef9fb512e65998e47) (MIT) at `04761bd602617b32b58faa7ef9fb512e65998e47`. Standard PTP/IP layouts were cross-checked against [libpict](https://github.com/petabyt/libpict/tree/9b5d9fdf22bf03d7ed2b323536c61b2a93c1e6c0) (Apache-2.0) and [libgphoto2](https://github.com/gphoto/libgphoto2/tree/31a2f4089f19aec6caca7920b03e3eb7a251c5b6) (LGPL). [fudge](https://github.com/petabyt/fudge/tree/4523e2cf7ec8b087005c93fd08b9438692955f64) (GPL-3.0) was consulted as a research reference only; no fudge source is included.
