import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let displayMonitor = DisplayMonitor.shared
    private let obsManager = OBSWebSocketManager.shared
    private let configStore = ConfigStore.shared

    // Menu items that need to be updated live.
    private var obsStatusMenuItem: NSMenuItem!
    private var sceneMenuItem: NSMenuItem!
    private var displayCountMenuItem: NSMenuItem!
    private var lastTriggerMenuItem: NSMenuItem!
    private var recordingStatusMenuItem: NSMenuItem!

    /// Tokens for the closure-based NotificationCenter observers so we can
    /// remove exactly the registrations we added (and only those).
    private var notificationObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // If OBSCENE_RENDER_SETTINGS=<path> is set, render the SettingsView
        // to a PNG offscreen and exit. Used by the release screenshot script
        // so we can capture the full settings view even on small external
        // displays where a native window would be clamped to visibleFrame.
        if let outputPath = ProcessInfo.processInfo.environment["OBSCENE_RENDER_SETTINGS"] {
            renderSettingsToPNG(path: outputPath)
            exit(0)
        }

        setupMenuBar()
        // Ask for banner permission up-front so the first trigger fire has a
        // decided answer. Users who deny keep full functionality without
        // banners.
        UserNotifier.requestPermission()
        displayMonitor.startMonitoring()
        connectToOBSIfConfigured()

        // Boot Sparkle auto-updater. Reads SUFeedURL / SUPublicEDKey /
        // SUEnableAutomaticChecks from Info.plist and begins its scheduled
        // check loop immediately. See OBScene/UpdaterManager.swift and
        // docs/RELEASING.md for the release-side signing + appcast flow.
        UpdaterManager.shared.start()

        let center = NotificationCenter.default

        notificationObservers.append(
            center.addObserver(forName: .displayTriggerFired, object: nil, queue: .main) { [weak self] note in
                self?.displayTriggerFired(note)
            }
        )

        notificationObservers.append(
            center.addObserver(forName: .displayUnplugTriggerFired, object: nil, queue: .main) { [weak self] note in
                self?.displayUnplugTriggerFired(note)
            }
        )

        notificationObservers.append(
            center.addObserver(forName: .obsConnectionChanged, object: nil, queue: .main) { [weak self] _ in
                self?.obsConnectionChanged()
            }
        )

        notificationObservers.append(
            center.addObserver(forName: .externalDisplayCountChanged, object: nil, queue: .main) { [weak self] note in
                self?.displayCountChanged(note)
            }
        )

        // Refresh menu state once up-front.
        refreshMenuState()

        // Decide whether to pop the settings window on launch:
        //   1. First-run (unconfigured) — always show settings so the user
        //      knows what to do.
        //   2. Manual launch (Finder double-click, Spotlight, Dock) — show
        //      settings so the menu-bar app gives visible feedback rather than
        //      silently going resident.
        //   3. Login-item launch (SMAppService / launchd at login) — stay
        //      silent; the user hasn't asked to see anything.
        //
        // We detect (3) via the AppleEvent that launched the process: when
        // macOS starts a login item it sets the keyAELaunchedAsLogInItem
        // property on the open-application event. Any other launch (double
        // click, Spotlight, `open -a`) omits it.
        let shouldShowSettingsOnLaunch =
            !configStore.config.hasBeenConfigured || !Self.launchedAsLoginItem()

        if shouldShowSettingsOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.openSettings()
            }
        }
    }

    /// Returns true when the process was launched by macOS as a login item
    /// (SMAppService / launchd at login), false when the user launched it
    /// directly (Finder, Spotlight, Dock, `open -a`). Used to decide whether
    /// to pop the settings window on launch.
    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else {
            // No AppleEvent at all — not a GUI launch. Treat as login item
            // so we stay silent (this also covers the screenshot-render
            // subprocess path, which exits before this is reached anyway).
            return true
        }

        // Only the open-application event is interesting.
        guard event.eventClass == kCoreEventClass, event.eventID == kAEOpenApplication else {
            return false
        }

        // The login-item flag is exposed via the AEPropData descriptor under
        // keyAEPropData; its enum value equals keyAELaunchedAsLogInItem when
        // launchd started us as a login item.
        let propDesc = event.paramDescriptor(forKeyword: keyAEPropData)
        return propDesc?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Called when the user re-launches the app while it's already running
    /// (double-clicking the .app in Finder, clicking it in the Dock, etc.).
    /// For an LSUIElement menu-bar app this is the user's only feedback that
    /// anything happened, so pop the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openSettings()
        }
        return true
    }

    deinit {
        let center = NotificationCenter.default
        for token in notificationObservers {
            center.removeObserver(token)
        }
        notificationObservers.removeAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Tidy up shared singletons so we don't leave a CG callback registered
        // or a WebSocket loop spinning if the process lingers (e.g. while
        // crash reporters or system services hold us alive briefly).
        displayMonitor.stopMonitoring()
        obsManager.disconnect()

        let center = NotificationCenter.default
        for token in notificationObservers {
            center.removeObserver(token)
        }
        notificationObservers.removeAll()
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // Ethan prefers the original "two screens" icon — a single,
            // static `display.2` template. No state-based swapping: the
            // dropdown menu already shows connection + display status.
            let image = NSImage(systemSymbolName: "display.2",
                                accessibilityDescription: "OBScene")
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        // Section: status
        let header = NSMenuItem(title: "OBScene", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.attributedTitle = NSAttributedString(
            string: "OBScene",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold)]
        )
        menu.addItem(header)

        obsStatusMenuItem = NSMenuItem(title: "OBS: Disconnected", action: nil, keyEquivalent: "")
        obsStatusMenuItem.isEnabled = false
        menu.addItem(obsStatusMenuItem)

        sceneMenuItem = NSMenuItem(title: "Scene: —", action: nil, keyEquivalent: "")
        sceneMenuItem.isEnabled = false
        menu.addItem(sceneMenuItem)

        displayCountMenuItem = NSMenuItem(title: "Displays: 0 / 1 external", action: nil, keyEquivalent: "")
        displayCountMenuItem.isEnabled = false
        menu.addItem(displayCountMenuItem)

        recordingStatusMenuItem = NSMenuItem(title: "Recording on connect: Off", action: nil, keyEquivalent: "")
        recordingStatusMenuItem.isEnabled = false
        menu.addItem(recordingStatusMenuItem)

        lastTriggerMenuItem = NSMenuItem(title: "Last trigger: Never", action: nil, keyEquivalent: "")
        lastTriggerMenuItem.isEnabled = false
        menu.addItem(lastTriggerMenuItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let reconnectItem = NSMenuItem(title: "Reconnect to OBS", action: #selector(reconnectOBS), keyEquivalent: "r")
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About OBScene", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        // "Check for Updates…" drives Sparkle's user-initiated update flow.
        // Target is UpdaterManager.shared — the selector on that class
        // calls `SPUStandardUpdaterController.checkForUpdates(_:)`.
        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(UpdaterManager.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = UpdaterManager.shared
        menu.addItem(checkForUpdatesItem)

        let githubItem = NSMenuItem(title: "OBScene on GitHub", action: #selector(openGitHub), keyEquivalent: "")
        githubItem.target = self
        menu.addItem(githubItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit OBScene", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    /// Recompute all of the live status menu items from current singletons.
    private func refreshMenuState() {
        let config = configStore.config
        let connected = obsManager.isConnected

        // OBS connection + scene
        if connected {
            obsStatusMenuItem.title = "OBS: Connected"
            if !obsManager.currentScene.isEmpty {
                sceneMenuItem.title = "Scene: \(obsManager.currentScene)"
            } else {
                sceneMenuItem.title = "Scene: —"
            }
        } else if let error = obsManager.connectionError, !error.isEmpty {
            obsStatusMenuItem.title = "OBS: \(truncate(error, limit: 50))"
            sceneMenuItem.title = "Scene: —"
        } else {
            obsStatusMenuItem.title = "OBS: Disconnected"
            sceneMenuItem.title = "Scene: —"
        }

        // External display status, shown as current / required.
        let current = displayMonitor.externalDisplayCount
        let required = config.requiredExternalDisplays
        let noun = required == 1 ? "display" : "displays"
        if current >= required {
            displayCountMenuItem.title = "Displays: \(current) / \(required) external (ready)"
        } else {
            displayCountMenuItem.title = "Displays: \(current) / \(required) external \(noun) (waiting)"
        }

        // Trigger-actions summary so users can see what'll happen at a glance.
        var actions: [String] = []
        if config.startRecording { actions.append("Record") }
        if config.startStreaming { actions.append("Stream") }
        if config.startVirtualCam { actions.append("Virtual Cam") }
        if config.startReplayBuffer { actions.append("Replay Buffer") }
        if actions.isEmpty {
            recordingStatusMenuItem.title = "Trigger actions: scene switch only"
        } else {
            recordingStatusMenuItem.title = "Trigger actions: \(actions.joined(separator: " + "))"
        }

        // The status-item symbol is fixed at `display.2` — see setupMenuBar.
        // Connection / readiness state lives in the dropdown menu items
        // above, so swapping the icon adds noise without information.
    }

    private func truncate(_ s: String, limit: Int) -> String {
        if s.count <= limit { return s }
        return String(s.prefix(limit - 1)) + "…"
    }

    // MARK: - Menu actions

    @objc private func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
            .environmentObject(configStore)
            .environmentObject(obsManager)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 920),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OBScene Settings"
        window.contentView = NSHostingView(rootView: settingsView)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        window.delegate = self

        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
    }

    @objc private func reconnectOBS() {
        connectToOBSIfConfigured()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

        // Build a small credits string with a clickable GitHub link.
        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(
            string: "Automates OBS recording & streaming when external displays connect.\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        ))
        let linkAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .link: URL(string: "https://github.com/EthanSK/OBScene")!,
            .foregroundColor: NSColor.linkColor
        ]
        credits.append(NSAttributedString(
            string: "github.com/EthanSK/OBScene",
            attributes: linkAttrs
        ))

        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "OBScene",
            .applicationVersion: version,
            .version: "Build \(build)",
            .credits: credits,
            .init(rawValue: "Copyright"): "Copyright © 2024 Ethan SK. MIT License."
        ]

        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/EthanSK/OBScene") {
            NSWorkspace.shared.open(url)
        }
    }

    private func connectToOBSIfConfigured() {
        let config = configStore.config
        guard config.hasBeenConfigured, !config.obsHost.isEmpty else { return }
        obsManager.connect(
            host: config.obsHost,
            port: config.obsPort,
            password: config.obsPassword
        )
    }

    // MARK: - Notification observers

    @objc private func displayTriggerFired(_ notification: Notification) {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        let timeString = formatter.string(from: Date())

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lastTriggerMenuItem.title = "Last trigger: \(timeString)"
            self.refreshMenuState()

            // Build a human summary of what actually happened so the banner
            // is useful, not just "Trigger fired".
            let config = self.configStore.config
            var parts: [String] = []
            if !config.selectedSceneCollection.isEmpty {
                parts.append("Collection → \(config.selectedSceneCollection)")
            }
            if !config.selectedProfile.isEmpty {
                parts.append("Profile → \(config.selectedProfile)")
            }
            if !config.selectedScene.isEmpty {
                parts.append("Scene → \(config.selectedScene)")
            }
            if config.startRecording { parts.append("Started recording") }
            if config.startStreaming { parts.append("Started streaming") }
            if config.startVirtualCam { parts.append("Started virtual camera") }
            if config.startReplayBuffer { parts.append("Started replay buffer") }
            let body = parts.isEmpty ? "Displays reached target count." : parts.joined(separator: "\n")

            UserNotifier.post(
                title: "OBScene trigger fired",
                body: body
            )
        }
    }

    @objc private func displayUnplugTriggerFired(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let config = self.configStore.config
            var parts: [String] = []
            if config.stopRecordingOnUnplug { parts.append("Stopped recording") }
            if config.stopStreamingOnUnplug { parts.append("Stopped streaming") }
            if config.stopVirtualCamOnUnplug { parts.append("Stopped virtual camera") }
            if config.stopReplayBufferOnUnplug { parts.append("Stopped replay buffer") }
            let body = parts.isEmpty ? "Displays disconnected." : parts.joined(separator: "\n")
            UserNotifier.post(
                title: "OBScene: displays unplugged",
                body: body
            )
            self.refreshMenuState()
        }
    }

    @objc private func obsConnectionChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshMenuState()
        }
    }

    @objc private func displayCountChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.refreshMenuState()
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        settingsWindow = nil
    }
}

extension AppDelegate {
    /// Offscreen render of the `SettingsView` at its natural content size,
    /// used by the release screenshot tooling (`OBSCENE_RENDER_SETTINGS=path`).
    fileprivate func renderSettingsToPNG(path: String) {
        // Pretend we're connected to OBS with some plausible scenes/profiles
        // so the settings view shows its fully-populated state rather than
        // the "Connect to OBS to configure scenes and profiles." placeholder.
        obsManager.isConnected = true
        obsManager.sceneCollections = ["Untitled"]
        obsManager.profiles = ["Untitled"]
        obsManager.scenes = ["Scene"]

        // Give the view a fixed width and let the height grow naturally,
        // then measure. We explicitly override `minHeight` with a tiny value
        // via `.frame` so the SettingsView's own `minHeight: 920` doesn't
        // inflate the fitting size — we want the intrinsic content height.
        let view = SettingsView()
            .environmentObject(configStore)
            .environmentObject(obsManager)
            .frame(minWidth: 680, idealWidth: 680, maxWidth: 680,
                   minHeight: 0, idealHeight: nil, maxHeight: .infinity)
            .fixedSize(horizontal: true, vertical: true)
            .background(Color(NSColor.windowBackgroundColor))

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 680, height: 2000)
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let size = NSSize(width: 680, height: fitting.height)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        // Render at @2x so we get a crisp PNG suitable for Retina displays
        // and the README. We draw into a bitmap whose pixel dimensions are
        // double the point size.
        let scale: CGFloat = 2.0
        let pixelW = Int(size.width * scale)
        let pixelH = Int(size.height * scale)

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW,
            pixelsHigh: pixelH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) else {
            NSLog("[OBScene] Failed to create bitmap rep")
            return
        }
        bitmap.size = size  // point size — cacheDisplay will scale up

        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            NSLog("[OBScene] Failed to encode PNG")
            return
        }

        do {
            try data.write(to: URL(fileURLWithPath: path))
            NSLog("[OBScene] Rendered SettingsView to \(path) (\(pixelW)x\(pixelH))")
        } catch {
            NSLog("[OBScene] Failed to write \(path): \(error)")
        }
    }
}

/// NSWindow subclass that refuses the default "clamp to visible screen"
/// behaviour, used only by `OBSCENE_SCREENSHOT=1` so we can render the
/// full-height settings view on small external displays for promo shots.


extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Pull the freshest state every time the menu drops down — cheap,
        // keeps scene/collection labels in sync with reality without needing
        // @Published subscriptions from AppKit land.
        refreshMenuState()
    }
}
