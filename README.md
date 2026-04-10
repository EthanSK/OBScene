# OBScene

**OBS + Scene** -- A macOS menu bar app that automatically controls OBS Studio when external displays are connected.

Plug in your monitors and OBScene takes care of the rest: switches your scene collection, profile, and scene, then optionally starts recording or streaming -- all hands-free.

![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/License-MIT-green)

<!-- Screenshots coming soon -->
<!-- ![OBScene Menu Bar](screenshots/menubar.png) -->
<!-- ![OBScene Settings](screenshots/settings.png) -->

## Features

- **Automatic Display Detection** -- Uses CoreGraphics display change notifications to detect when external monitors are connected or disconnected
- **Configurable Trigger** -- Set how many external displays must be connected before OBScene activates (e.g., "trigger when 2 external displays are connected")
- **OBS Scene Control** -- Automatically switch scene collection, profile, and active scene
- **Recording & Streaming** -- Optionally start recording and/or streaming when triggered
- **Configurable Delay** -- Set a delay (default 15 seconds) before actions execute, giving OBS time to initialize
- **OBS WebSocket v5** -- Connects to OBS via the built-in WebSocket server (OBS 28+), no plugins required
- **Native macOS** -- Pure Swift + SwiftUI, runs as a lightweight menu bar app with no dock icon
- **Persistent Configuration** -- All settings saved locally via UserDefaults

## Requirements

- macOS 13.0 (Ventura) or later
- OBS Studio 28+ (includes obs-websocket v5)
- OBS WebSocket server enabled (Tools > WebSocket Server Settings)

## Installation

### Build from Source

1. Clone the repository:
   ```bash
   git clone https://github.com/EthanSK/OBScene.git
   cd OBScene
   ```

2. Open in Xcode:
   ```bash
   open OBScene.xcodeproj
   ```

3. Build and run (Cmd+R)

4. OBScene will appear in your menu bar

## Setup

1. **Enable OBS WebSocket Server:**
   - Open OBS Studio
   - Go to Tools > WebSocket Server Settings
   - Check "Enable WebSocket server"
   - Note the port (default: 4455) and set a password if desired

2. **Configure OBScene:**
   - Click the OBScene icon in your menu bar
   - Click "Settings..."
   - Enter your OBS WebSocket connection details and click "Connect"
   - Select the scene collection, profile, and scene to switch to
   - Set how many external displays should trigger the automation
   - Enable recording/streaming if desired
   - Close the settings window -- OBScene will monitor displays in the background

3. **Plug in your displays** and OBScene handles the rest!

## How It Works

```
External display connected
        |
        v
Display count >= threshold?
        |
      [yes]
        |
        v
Wait configured delay (default 15s)
        |
        v
Switch scene collection (if set)
        |
        v
Switch profile (if set)
        |
        v
Switch scene (if set)
        |
        v
Start recording/streaming (if enabled)
```

OBScene uses `CGDisplayRegisterReconfigurationCallback` to receive real-time display change notifications from macOS. When the number of external displays reaches your configured threshold, it waits for the configured delay, then sends commands to OBS via WebSocket.

## OBS WebSocket v5 Protocol

OBScene communicates with OBS using the WebSocket v5 protocol (included in OBS 28+). It implements:

- SHA256 challenge-response authentication
- Scene collection and profile switching
- Scene switching
- Recording and streaming control

No additional OBS plugins are needed.

## Architecture

```
OBSceneApp.swift          -- App entry point (@main)
AppDelegate.swift         -- Menu bar setup, window management
ConfigStore.swift         -- UserDefaults-backed configuration
DisplayMonitor.swift      -- CoreGraphics display change detection
OBSWebSocketManager.swift -- OBS WebSocket v5 client with auth
SettingsView.swift        -- SwiftUI configuration UI
```

## License

MIT License. See [LICENSE](LICENSE) for details.
