# OBScene

**OBS + Scene** — a tiny macOS menu bar app that drives OBS Studio when you plug in your external displays.

Dock into your battlestation and OBScene takes care of the boring bits: it switches your scene collection, profile, and active scene, then (optionally) starts recording, streaming, the virtual camera, or the replay buffer. Unplug and it can stop everything just as cleanly. All hands-free, all local.

<div align="center">
  <img src="Resources/screenshot-settings.png" alt="OBScene settings window" width="600">
</div>

![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## Features

- **Automatic display detection** — uses CoreGraphics display-reconfiguration callbacks to react to monitors being plugged in or yanked out.
- **Configurable threshold** — decide how many external displays must be connected before OBScene fires (e.g. "when 1 external display is connected").
- **Scene / profile / scene collection switching** — pick exactly what OBS should switch to, or leave any of them untouched.
- **Four trigger actions** — independent toggles for **Recording**, **Streaming**, **Virtual Camera**, and **Replay Buffer**. Pick any combination.
- **Stop on unplug** — optionally stop any of the four actions the moment displays drop below the threshold. Perfect for "record while I'm docked, stop when I pack up."
- **Configurable delay** — a debounce window (default 5s) before the start actions fire, so OBS has time to settle after a display change.
- **OBS WebSocket v5** — talks to OBS via the built-in WebSocket server shipped with OBS 28+. No extra plugins.
- **Native macOS** — pure Swift + SwiftUI menu bar app. No dock icon, no Electron, no background tax.
- **Launch at Login** — one toggle, backed by `ServiceManagement`.
- **Persistent configuration** — everything saved locally via `UserDefaults`.

## Requirements

- macOS 13.0 (Ventura) or later
- OBS Studio 28+ (bundles obs-websocket v5)
- OBS WebSocket server enabled (Tools → WebSocket Server Settings)

## Installation

### Build from source

```bash
git clone https://github.com/EthanSK/OBScene.git
cd OBScene
open OBScene.xcodeproj
```

Then hit **Cmd+R** in Xcode. OBScene will appear in your menu bar.

Prefer the command line? You can build without Xcode:

```bash
mkdir -p build
swiftc -O -target arm64-apple-macos13 -parse-as-library \
    -o build/OBScene OBScene/*.swift
```

A prebuilt release download is on the roadmap — for now, build from source.

## Setup

1. **Enable OBS WebSocket**
   - Open OBS Studio.
   - Go to **Tools → WebSocket Server Settings**.
   - Check *Enable WebSocket server*.
   - Note the port (default `4455`) and set a password.

2. **Launch OBScene**
   - Run the app. A `display.2` icon will appear in your menu bar.

3. **Open Settings**
   - Click the menu bar icon and choose **Settings…**.

4. **Connect to OBS**
   - Fill in the WebSocket **Host**, **Port**, and **Password**.
   - Click **Connect**. The status dot goes green when the handshake succeeds.

5. **Pick your OBS targets** *(optional)*
   - Choose a **Scene Collection**, **Profile**, and **Scene** to switch to.
   - Leave any dropdown on *(Don't change)* to skip that step.

6. **Pick your trigger actions**
   - Toggle any combination of **Start Recording**, **Start Streaming**, **Start Virtual Camera**, and **Start Replay Buffer**.
   - Under each, toggle **Also stop … when displays are unplugged** to automatically tear down when you undock.

7. **Set the display threshold and delay**
   - Choose how many external displays should trigger OBScene.
   - Set the debounce delay (default 5 seconds) before start actions fire.

8. **Launch at Login** *(optional)*
   - Toggle it on so OBScene is always watching. You may need to approve it once in **System Settings → General → Login Items**.

Close the settings window and you're done. OBScene runs quietly in the menu bar and will do its thing the next time your displays change.

## How it works

```
External display change
          │
          ▼
Display count ≥ threshold?
          │
      ┌───┴───┐
     yes     no
      │       │
      ▼       ▼
  Wait N   Count crossed
  seconds  threshold going DOWN?
      │       │
      ▼       ▼
  Switch    Stop recording
  collection  (if enabled)
      │       │
      ▼       ▼
  Switch    Stop streaming
  profile     (if enabled)
      │
      ▼
  Switch scene
      │
      ▼
  Start recording /
  streaming /
  virtual cam /
  replay buffer
```

OBScene registers a `CGDisplayRegisterReconfigurationCallback` to receive real-time display events from macOS. On each event, it recounts external displays (excluding the built-in one) and compares against your configured threshold.

- **Going up** (count crosses threshold upward): schedules a delayed trigger. If displays are unplugged before the delay elapses, the pending trigger is cancelled.
- **Going down** (count crosses threshold downward): immediately fires the unplug trigger, which sends `StopRecord` / `StopStream` / `StopVirtualCam` / `StopReplayBuffer` to OBS for whichever stop-on-unplug options you enabled.

Commands reach OBS over the WebSocket v5 protocol, with SHA-256 challenge-response authentication if you've set a password.

## Configuration reference

All settings are persisted locally in `UserDefaults` under the key `OBSceneConfig`.

| Setting | Description | Default |
| --- | --- | --- |
| **Launch at Login** | Start OBScene automatically on login via `SMAppService`. | off |
| **Host** | OBS WebSocket host. | `localhost` |
| **Port** | OBS WebSocket port. | `4455` |
| **Password** | OBS WebSocket password (optional). | *(empty)* |
| **Scene Collection** | Collection to switch to on trigger, or leave unchanged. | *(unchanged)* |
| **Profile** | Profile to switch to on trigger, or leave unchanged. | *(unchanged)* |
| **Scene** | Program scene to switch to on trigger, or leave unchanged. | *(unchanged)* |
| **External display threshold** | Number of external displays required to fire the trigger. | `1` |
| **Trigger delay** | Seconds to wait after the threshold is crossed before firing start actions. | `5` |
| **Start Recording** | Call `StartRecord` on trigger. | off |
| **Also stop recording when displays are unplugged** | Call `StopRecord` immediately when the display count drops below the threshold. | off |
| **Start Streaming** | Call `StartStream` on trigger. | off |
| **Also stop streaming when displays are unplugged** | Call `StopStream` immediately when the display count drops below the threshold. | off |
| **Start Virtual Camera** | Call `StartVirtualCam` on trigger. | off |
| **Also stop virtual camera when displays are unplugged** | Call `StopVirtualCam` immediately when the display count drops below the threshold. | off |
| **Start Replay Buffer** | Call `StartReplayBuffer` on trigger. | off |
| **Also stop replay buffer when displays are unplugged** | Call `StopReplayBuffer` immediately when the display count drops below the threshold. | off |

## Architecture

OBScene is intentionally small — ~6 Swift files, no third-party dependencies:

```
OBSceneApp.swift          App entry point (@main, NSApplicationDelegateAdaptor)
AppDelegate.swift         Menu bar item, settings window, notification wiring
ConfigStore.swift         UserDefaults-backed AppConfig with forward-compatible decoding
DisplayMonitor.swift      CoreGraphics display monitoring + trigger scheduling
OBSWebSocketManager.swift OBS WebSocket v5 client (auth, requests, responses)
SettingsView.swift        SwiftUI configuration UI
```

Key technology choices:

- **Swift + SwiftUI** for the UI, embedded in an `NSWindow` hosted by a classic `NSApplicationDelegate` so the app can live purely in the menu bar.
- **CoreGraphics** (`CGDisplayRegisterReconfigurationCallback`) for display change detection — the same API OBS and other pro tools rely on.
- **URLSessionWebSocketTask** for the OBS WebSocket client, with SHA-256 challenge-response auth implemented via `CommonCrypto`. No external WebSocket library.
- **ServiceManagement** (`SMAppService`) for Launch at Login, the modern approach that works with app translocation and user approval flows.

## Contributing

Issues and PRs welcome. OBScene is deliberately small — if you have a feature idea, open an issue first to discuss fit and scope.

Rough guidelines:

- Keep it native. No SPM dependencies unless there's a strong reason.
- Keep it small. The whole app should remain readable in an afternoon.
- Match the existing Swift style: clear comments when anything subtle is happening, `[weak self]` in long-lived closures, no force-unwraps in production paths.

## License

MIT License. See [LICENSE](LICENSE) for details.
