# OBScene

**OBS + Scene** — a macOS menu bar app that drives OBS Studio and safely moves finished recordings when your hardware changes.

Plug in your battlestation displays, attach a USB capture device, or hit a custom trigger and OBScene takes care of the boring bits: it switches scene collection, profile, and active scene, then (optionally) starts recording, streaming, the virtual camera, or the replay buffer. Unplug and it cleans up just as quietly. Build as many profiles as you want — display profiles for the dock, USB profiles for the capture card, plug-in vs plug-out variants — and let OBScene wire them up. All hands-free, all local.

**[ethansk.github.io/OBScene](https://ethansk.github.io/OBScene/)** — landing page with feature tour and screenshots.

<div align="center">
  <img src="Resources/screenshot-menubar.png" alt="OBScene menu bar dropdown" width="260">
  &nbsp;
  <img src="Resources/screenshot-settings.png" alt="OBScene settings window showing a Display-triggered profile with plug-in/plug-out mode, trigger delay, and per-action delay" width="440">
</div>

![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![Latest](https://img.shields.io/github/v/release/EthanSK/OBScene?label=release)
![License](https://img.shields.io/badge/License-MIT-green)

## What it does

- **Trigger profiles.** Each profile is one rule: *when X happens, do Y to OBS.* Build as many as you need, run them in parallel, enable/disable per profile.
- **Two trigger types.**
  - **External display** — fires when the count of connected external monitors crosses a threshold you pick (e.g. "when 1 external display is connected").
  - **USB device** — fires when a specific USB device is plugged in or unplugged. Match by friendly name (volume label) or by a substring of the device name; the picker lists every connected device with vendor/product info.
- **Plug-in vs plug-out modes.** Each profile fires either on the connect edge or the disconnect edge. Want "switch scenes when the dock connects" *and* "stop recording when it disconnects"? That's two profiles, one of each mode.
- **OBS scene switching.** Per profile, pick a scene collection, profile, and program scene to switch to. Leave any of the three on *(Don't change)* to skip that step.
- **Trigger actions.** Per profile, mix and match any of:
  - Start / Stop **Recording**
  - Start / Stop **Streaming**
  - Start / Stop **Virtual Camera**
  - Start / Stop **Replay Buffer**
- **Configurable delays.** Set a debounce delay before the trigger fires (default 5s) so OBS has time to settle after a hardware change, plus an optional per-action stagger (default 0s, fire all at once) for finicky setups that don't like simultaneous start commands.
- **Run-on-activate shell hook.** Each profile can run an arbitrary shell command when it activates (under your login shell, with full PATH/aliases). Useful for invoking external CLI tools, switching Restream channels, kicking off a script that prepares your OBS config, etc. Output is logged to `~/Library/Logs/OBScene/script-runs.log`.
- **Restart OBS before run.** For workflows that require an OBS restart to pick up state (e.g. **Custom Browser Dock** URLs/cookies — there's no OBS API to refresh those), a profile can gracefully quit OBS, wait for it to relaunch, then run the script. Stops streaming/recording first, sweeps stale crash sentinels, and skips the restart if OBS is currently capturing (won't kill a live session). Toggle whether the script runs before or after the restart.
- **Mission Control Space restoration.** When OBScene restarts OBS for you, it remembers which Space (Mission Control workspace) the OBS window was on and moves it back after relaunch — so the restart doesn't yank OBS onto whichever Space you're currently viewing. Uses the same private SkyLight SPI yabai and Hammerspoon rely on, with the macOS 14.5+ compat-ID workaround. Persisted across runs.
- **Safe-Mode dialog auto-dismiss.** OBS shows a "did not shut down properly — Launch Normally / Safe Mode / Cancel" dialog after an unclean exit. When OBScene auto-launches OBS on a trigger, that modal would stall the trigger forever; the dialog dismisser watches for it via the Accessibility API and clicks **Launch Normally** for you. Matches OBS 28.x and 32.x button labels.
- **Auto-launch OBS.** If OBS isn't running when a trigger fires, OBScene launches it and polls the WebSocket port until it comes up, then runs the actions.
- **Browser refresh.** Optionally refreshes all open tabs in any running browser (Chrome, Safari, Arc, Brave, Edge, …) when a profile fires. Useful for browser-based stream overlays that get glitchy after a display change.
- **Activity log.** A live in-app feed of every event — user-visible by default, with a verbose toggle that shows the full debug stream (restart pipeline checkpoints, WebSocket reconnects, sentinel sweeps, etc.). Also written to `~/Library/Logs/OBScene/activity.log`.
- **Automatic recording transfers.** Choose a recordings folder on the Mac and a destination folder on an external drive. OBScene identifies the exact drive by filesystem UUID, starts when that drive mounts (and rechecks every 15 minutes while it remains attached), preserves subfolders, and posts start/completion/error notifications.
- **Verified retention cleanup.** Every recording is copied through a hidden temporary file and SHA-256 verified at its final destination. The laptop original remains for 7 days by default (configurable); when it becomes eligible, OBScene hashes both files again while the backup drive is present. A missing or changed byte keeps the laptop copy and restarts the transfer clock.
- **OBS WebSocket v5.** Talks to OBS via the built-in WebSocket server shipped with OBS 28+. No extra plugins. SHA-256 challenge-response auth.
- **Native macOS.** Pure Swift + SwiftUI menu bar app. No dock icon, no Electron, no background tax.
- **Launch at Login.** One toggle, backed by `ServiceManagement` (`SMAppService`).
- **Persistent configuration.** Everything saved locally via `UserDefaults`.
- **Automatic updates.** Sparkle 2.x checks the [appcast feed](https://ethansk.github.io/OBScene/appcast.xml) on launch and every 24h, downloads in the background, and prompts you to install + relaunch. EdDSA-signed. Use **Check for Updates…** in the menu-bar dropdown for an on-demand check.

## Requirements

- macOS 13.0 (Ventura) or later
- OBS Studio 28+ (bundles obs-websocket v5)
- OBS WebSocket server enabled (Tools → WebSocket Server Settings)
- **Accessibility permission** for OBScene (only needed for the Safe-Mode dialog auto-dismiss; the rest of the app works without it)

## Installation

### Download a release

Grab the latest signed, notarised build from the [Releases page](https://github.com/EthanSK/OBScene/releases/latest):

- **DMG** (recommended): [OBScene-latest-mac-universal.dmg](https://github.com/EthanSK/OBScene/releases/latest/download/OBScene-latest-mac-universal.dmg) — open and drag OBScene.app into Applications.
- **ZIP**: [OBScene-latest-mac-universal.zip](https://github.com/EthanSK/OBScene/releases/latest/download/OBScene-latest-mac-universal.zip) — for scripted installs.

Both assets are **universal binaries** (Apple Silicon + Intel) built and published by [`.github/workflows/release.yml`](.github/workflows/release.yml) on every push to `main`. Once Developer ID secrets are configured the releases are signed with `Developer ID Application` and notarised by Apple; until then each release is ad-hoc signed and will prompt Gatekeeper on first launch. See [`docs/RELEASING.md`](docs/RELEASING.md) for the release setup.

**After the first install, updates are automatic.** OBScene bundles Sparkle 2.x and checks https://ethansk.github.io/OBScene/appcast.xml on every launch plus every 24 hours, downloads new versions in the background, then prompts you to install + relaunch. Disable automatic checks from the "Check for Updates…" dialog if you'd rather update manually.

### Build from source

```bash
git clone https://github.com/EthanSK/OBScene.git
cd OBScene
open OBScene.xcodeproj
```

Then hit **Cmd+R** in Xcode. OBScene will appear in your menu bar.

Prefer the command line? You can build a universal `.app` bundle with one script:

```bash
./scripts/build-app.sh
open build/OBScene.app
```

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
   - Click **Connect**. The status pill goes green when the handshake succeeds.

5. **Grant Accessibility permission** *(optional but recommended)*
   - Required only for the Safe-Mode dialog auto-dismiss. Without it the rest of the app works, but OBS's "did not shut down properly" modal will block any trigger that auto-launches OBS until you click through it manually.
   - **System Settings → Privacy & Security → Accessibility**, toggle OBScene on.

6. **Launch at Login** *(optional)*
   - Toggle it on so OBScene is always watching. You may need to approve it once in **System Settings → General → Login Items**.

## Configure profiles

The Settings window is split into a **left column** (OBS connection + profiles list) and a **right column** (updates, general, testing, activity feed).

To create a profile:

1. Click the **+** in the profile tab bar at the top of the profiles section.
2. **Name** the profile and tick **Enabled** (profiles can be toggled off without being deleted).
3. **Pick a trigger type** — *External Display* or *USB Device*.
   - **Display:** set how many external displays must be connected to fire the trigger.
   - **USB Device:** pick a device from the dropdown (lists every USB device currently attached, with vendor and volume-label info), or choose *Custom name…* and type a substring to match by name (useful when the device isn't currently plugged in).
4. **Pick a mode** — *Plug in* (fires on the connect edge) or *Plug out* (fires on the disconnect edge).
5. **Set the trigger delay** (default 5s) — debounce window after the edge crosses, before any actions fire. If the displays/USB drop again inside the window, the pending trigger is cancelled.
6. **Set the delay between actions** (default 0s) — stagger between successive actions when the profile fires. Leave at 0 to fire them all at once.
7. **Pick OBS targets** *(optional)* — Scene Collection, Profile, Scene. Leave any on *(Don't change)* to skip.
8. **Add trigger actions** — click **+** in the actions list and pick from Start/Stop Recording, Streaming, Virtual Camera, Replay Buffer. Mix and match freely (e.g. *start recording* + *stop streaming* in the same profile).
9. **Run on activate** *(optional)* — paste a shell command to run when this profile fires. Toggle **Restart OBS before run** if you need OBS to restart first (for Custom Browser Dock refresh etc.); toggle **Run script BEFORE the OBS restart** to flip the order.
10. **Refresh browsers on trigger** *(optional)* — reload all open tabs in running browsers when the profile fires.

Repeat for each profile you want. Close the settings window and you're done. OBScene runs quietly in the menu bar and reacts to your hardware in the background.

## Configure automatic recording transfers

1. Open **Settings…** and select **File Transfers** at the top.
2. Click **Set Up Transfer…**, then choose the folder where OBS records on this Mac.
3. Choose a destination folder on the external backup drive. The drive must be connected for this initial setup; after that OBScene recognizes it by filesystem UUID even if its name or `/Volumes` mount path changes.
4. Leave **Keep laptop originals for 7 days** at its safe default, or choose another retention period.
5. Keep **Enabled** on and enable **Launch at Login** under OBS Automation → General so OBScene is always watching.

The first check runs immediately. Later checks run when the drive mounts, every 15 minutes while OBScene is open, or when you choose **Check File Transfers Now** from Settings or the menu bar. Files changed within the last two minutes are treated as active recordings and retried later. Interrupted or failed copies never make a laptop original eligible for deletion.

## How it works

OBScene registers a `CGDisplayRegisterReconfigurationCallback` for display events and `IOServiceAddMatchingNotification` (via IOKit) for USB hot-plug events. Each event triggers a per-profile evaluation:

- **Going up / plug-in** (count crosses threshold upward, or a matching USB device connects): schedules a delayed trigger. If the hardware drops before the delay elapses, the pending trigger is cancelled.
- **Going down / plug-out** (count crosses threshold downward, or a matching USB device disconnects): immediately fires the unplug trigger.

When a trigger fires, OBScene:

1. (If configured) launches OBS or reconnects to the existing instance.
2. (If configured) gracefully restarts OBS — stops any active stream/record first (capped at ~20s for ffmpeg-mux to finalise), waits for graceful exit (capped at 30s, never SIGKILL), sweeps stale crash sentinels, relaunches, polls the WebSocket until ready, then restores the Mission Control Space the OBS window was on.
3. (If configured) runs your shell command — either before or after the restart, depending on the toggle.
4. Switches scene collection / profile / scene as configured.
5. Fires the trigger actions (start/stop recording, streaming, virtual cam, replay buffer) with the configured per-action delay.
6. (If configured) refreshes all open browser tabs in running browsers.

Commands reach OBS over the WebSocket v5 protocol, with SHA-256 challenge-response authentication if you've set a password.

File transfers are independent of the OBS connection. `NSWorkspace` mount notifications wake the transfer manager, which resolves the configured volume UUID to its current mount point. Each source file is streamed into a hidden sibling on the destination, the source is checked for changes during the copy, the final destination is independently SHA-256 hashed, and only then is an atomic manifest entry written under `~/Library/Application Support/OBScene/`. Retention deletion requires that manifest proof plus a fresh hash of both files.

## Caveats

- **Private SkyLight SPI for Space restoration.** OBScene calls undocumented `SkyLight.framework` symbols (the same ones yabai, Hammerspoon, Rectangle, etc. use) to capture the Space the OBS window was on and move it back after a restart. These have been stable for ~10 macOS versions but Apple could break them on any major release; OBScene resolves them dynamically via `dlsym` and degrades to a no-op (with a single warning in the activity log) if a symbol disappears.
- **macOS 14.5+ workaround.** Apple changed Mission Control internals in Sonoma 14.5 such that the historical window-to-space SPI silently no-ops. On 14.5+ OBScene uses the same compat-ID dance yabai and Hammerspoon use (tag the target Space with a temporary workspace ID, assign the window list, clear the ID). On older releases the legacy `CGSMoveWindowsToManagedSpace` path is used.
- **Accessibility permission required for Safe-Mode dismiss.** OBScene needs Accessibility permission to detect and click through OBS's "did not shut down properly" modal. Without it the rest of the app works fine; only the auto-dismiss feature silently no-ops.
- **OBS restart never kills a live capture.** If OBS is currently recording or streaming, the **Restart OBS before run** toggle is honoured *only* after the active outputs stop cleanly. If they don't stop within ~20s, OBScene aborts the restart rather than risk corrupting an active recording.
- **Run-on-activate runs arbitrary shell.** This is a deliberate power-user escape hatch (e.g. `restream-channel-switch …`), not a sandboxed API. Only configure scripts you trust.
- **The backup drive must be mounted for cleanup.** OBScene never deletes a retained laptop original using stale history alone. If the drive is absent, the rule waits; if the destination is missing or fails its fresh hash, the original stays and is copied again.
- **Not on the App Store.** OBScene needs IOKit, AppleScript, accessibility, and private SkyLight access — none of which are sandbox-friendly. It ships as a Developer ID-signed, notarised universal binary distributed via GitHub Releases.
- **Universal binary distribution only.** No Homebrew tap yet — installation is DMG/ZIP from the [Releases page](https://github.com/EthanSK/OBScene/releases/latest).

## Release status

Latest release: **v1.47** ([appcast.xml](https://ethansk.github.io/OBScene/appcast.xml)). Universal binary, macOS 13+. Publishes automatically on every push to `main` via [`.github/workflows/release.yml`](.github/workflows/release.yml).

## Architecture

OBScene is intentionally small — pure Swift + SwiftUI, only Sparkle as a third-party dependency:

```
OBSceneApp.swift              App entry point (@main, NSApplicationDelegateAdaptor)
AppDelegate.swift             Menu bar item, settings window, notification wiring
ConfigStore.swift             UserDefaults-backed AppConfig with multi-profile schema
DisplayMonitor.swift          CoreGraphics display monitoring + per-profile trigger scheduling
USBMonitor.swift              IOKit USB hot-plug monitoring + DiskArbitration volume label resolution
FileTransferModels.swift      Transfer rules, manifest proof, and UI state types
FileTransferEngine.swift      Hidden-temp copy, SHA-256 verification, destructive safety gate
FileTransferManager.swift     Volume mount watcher, scheduling, manifest persistence, notifications
FileTransferSettingsView.swift SwiftUI setup, retention, status, and manual-run UI
OBSWebSocketManager.swift     OBS WebSocket v5 client + OBSAppController quit/relaunch pipeline
SafeModeDialogDismisser.swift Accessibility-API watcher for the OBS "did not shut down properly" modal
SpaceManager.swift            Private SkyLight SPI for Mission Control Space restoration
ScriptRunner.swift            Per-profile shell-command hook (detached, login shell, logged)
BrowserRefresher.swift        AppleScript-based tab refresh across running browsers
UpdaterManager.swift          Sparkle 2.x wrapper (auto-check + auto-download)
SettingsView.swift            SwiftUI configuration UI (profiles, OBS connection, activity, updates)
```

Key technology choices:

- **Swift + SwiftUI** for the UI, embedded in an `NSWindow` hosted by a classic `NSApplicationDelegate` so the app can live purely in the menu bar (`LSUIElement=true`).
- **CoreGraphics** (`CGDisplayRegisterReconfigurationCallback`) for display change detection.
- **IOKit + DiskArbitration** for USB hot-plug detection and volume-label resolution.
- **URLSessionWebSocketTask** for the OBS WebSocket client, with SHA-256 challenge-response auth implemented via `CommonCrypto`. No external WebSocket library.
- **Accessibility API** (`AXUIElement`) for the Safe-Mode dialog dismisser.
- **SkyLight private framework** (resolved via `dlsym` at first use) for Mission Control Space capture / restore. Same approach as yabai and Hammerspoon.
- **Sparkle 2.x** vendored under [`Frameworks/`](Frameworks) for auto-updates.
- **ServiceManagement** (`SMAppService`) for Launch at Login.
- **GitHub Actions** for build / sign / notarise / release / appcast publishing on every push to `main`. See [`docs/RELEASING.md`](docs/RELEASING.md).

## Contributing

Issues and PRs welcome. OBScene is a personal tool but I'm happy to take focused contributions — open an issue first to discuss fit and scope.

Rough guidelines:

- Keep it native. No SPM dependencies unless there's a strong reason.
- Match the existing Swift style: clear comments when anything subtle is happening, `[weak self]` in long-lived closures, no force-unwraps in production paths.
- The OBS restart / Space restore / Safe-Mode dismiss paths are all **load-bearing** — there's a lot of macOS-internals nuance buried in their comments. If you're touching them, read the comments first; if a comment is wrong, fix it in the same PR.

## License

MIT License. See [LICENSE](LICENSE) for details.
