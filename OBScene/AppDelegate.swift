import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let displayMonitor = DisplayMonitor.shared
    private let usbMonitor = USBMonitor.shared
    private let obsManager = OBSWebSocketManager.shared
    private let configStore = ConfigStore.shared

    // Menu items that need to be updated live.
    private var obsStatusMenuItem: NSMenuItem!
    private var sceneMenuItem: NSMenuItem!
    private var displayCountMenuItem: NSMenuItem!
    private var profilesSummaryMenuItem: NSMenuItem!
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

        // If OBSCENE_RENDER_MENU=<path> is set, render a SwiftUI facsimile
        // of the menu-bar dropdown (NSMenu isn't a capturable window, so we
        // rebuild the same layout as a SwiftUI view and render it to PNG
        // offscreen). Used by the README + landing page screenshots.
        if let outputPath = ProcessInfo.processInfo.environment["OBSCENE_RENDER_MENU"] {
            renderMenuBarDropdownToPNG(path: outputPath)
            exit(0)
        }

        setupMenuBar()
        UserNotifier.requestPermission()
        displayMonitor.startMonitoring()
        usbMonitor.startMonitoring()
        connectToOBSIfConfigured()

        // Boot Sparkle auto-updater.
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

        // USB device connection/disconnection handlers
        notificationObservers.append(
            center.addObserver(forName: .usbDeviceConnected, object: nil, queue: .main) { [weak self] note in
                self?.handleUSBDeviceConnected(note)
            }
        )

        notificationObservers.append(
            center.addObserver(forName: .usbDeviceDisconnected, object: nil, queue: .main) { [weak self] note in
                self?.handleUSBDeviceDisconnected(note)
            }
        )

        // Refresh menu state once up-front.
        refreshMenuState()

        let shouldShowSettingsOnLaunch =
            !configStore.config.hasBeenConfigured || !Self.launchedAsLoginItem()

        if shouldShowSettingsOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.openSettings()
            }
        }
    }

    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else {
            return true
        }
        guard event.eventClass == kCoreEventClass, event.eventID == kAEOpenApplication else {
            return false
        }
        let propDesc = event.paramDescriptor(forKeyword: keyAEPropData)
        return propDesc?.enumCodeValue == keyAELaunchedAsLogInItem
    }

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
        displayMonitor.stopMonitoring()
        usbMonitor.stopMonitoring()
        obsManager.disconnect()

        let center = NotificationCenter.default
        for token in notificationObservers {
            center.removeObserver(token)
        }
        notificationObservers.removeAll()
    }

    // MARK: - USB Device Handling

    private func handleUSBDeviceConnected(_ notification: Notification) {
        guard let deviceName = notification.userInfo?["deviceName"] as? String else { return }

        let matchingProfiles = ConfigStore.shared.usbProfilesMatching(deviceName: deviceName)
        for profile in matchingProfiles {
            print("[OBScene] USB device '\(deviceName)' matched profile '\(profile.name)'")
            ActivityLog.shared.log(.info, "USB device '\(deviceName)' matched profile '\(profile.name)'")
            displayMonitor.scheduleUSBTrigger(for: profile)
        }
    }

    private func handleUSBDeviceDisconnected(_ notification: Notification) {
        guard let deviceName = notification.userInfo?["deviceName"] as? String else { return }

        let matchingProfiles = ConfigStore.shared.usbProfilesMatching(deviceName: deviceName)
        for profile in matchingProfiles {
            print("[OBScene] USB device '\(deviceName)' disconnected — unplug trigger for '\(profile.name)'")
            ActivityLog.shared.log(.info, "USB device '\(deviceName)' disconnected (\(profile.name))")
            displayMonitor.executeUSBUnplugTrigger(for: profile)
        }
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
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

        displayCountMenuItem = NSMenuItem(title: "Displays: 0 external", action: nil, keyEquivalent: "")
        displayCountMenuItem.isEnabled = false
        menu.addItem(displayCountMenuItem)

        profilesSummaryMenuItem = NSMenuItem(title: "Profiles: none", action: nil, keyEquivalent: "")
        profilesSummaryMenuItem.isEnabled = false
        menu.addItem(profilesSummaryMenuItem)

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

        // External display count
        let current = displayMonitor.externalDisplayCount
        displayCountMenuItem.title = "Displays: \(current) external"

        // Profiles summary
        let enabledProfiles = config.profiles.filter { $0.isEnabled }
        if enabledProfiles.isEmpty {
            profilesSummaryMenuItem.title = "Profiles: none enabled"
        } else {
            let names = enabledProfiles.map { $0.name }.joined(separator: ", ")
            profilesSummaryMenuItem.title = "Profiles: \(names)"
        }

        // Trigger-actions summary across all enabled profiles.
        var actions = Set<String>()
        for profile in enabledProfiles {
            if profile.startRecording { actions.insert("Record") }
            if profile.startStreaming { actions.insert("Stream") }
            if profile.startVirtualCam { actions.insert("Virtual Cam") }
            if profile.startReplayBuffer { actions.insert("Replay Buffer") }
        }
        if actions.isEmpty {
            recordingStatusMenuItem.title = "Trigger actions: scene switch only"
        } else {
            recordingStatusMenuItem.title = "Trigger actions: \(actions.sorted().joined(separator: " + "))"
        }
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
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OBScene Settings"
        window.contentView = NSHostingView(rootView: settingsView)
        window.minSize = NSSize(width: 640, height: 500)
        window.maxSize = NSSize(width: 1600, height: 1200)
        window.center()
        window.setFrameAutosaveName("OBSceneSettings")
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

            // Extract profile from notification if available.
            let profile = notification.userInfo?["profile"] as? TriggerProfile
            let profileName = profile?.name ?? "Unknown"

            var parts: [String] = ["Profile: \(profileName)"]
            if let p = profile {
                if !p.selectedSceneCollection.isEmpty {
                    parts.append("Collection → \(p.selectedSceneCollection)")
                }
                if !p.selectedProfile.isEmpty {
                    parts.append("Profile → \(p.selectedProfile)")
                }
                if !p.selectedScene.isEmpty {
                    parts.append("Scene → \(p.selectedScene)")
                }
                if p.startRecording { parts.append("Started recording") }
                if p.startStreaming { parts.append("Started streaming") }
                if p.startVirtualCam { parts.append("Started virtual camera") }
                if p.startReplayBuffer { parts.append("Started replay buffer") }
            }
            let body = parts.joined(separator: "\n")

            UserNotifier.post(
                title: "OBScene trigger fired",
                body: body
            )
        }
    }

    @objc private func displayUnplugTriggerFired(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let profile = notification.userInfo?["profile"] as? TriggerProfile
            let profileName = profile?.name ?? "Unknown"

            var parts: [String] = ["Profile: \(profileName)"]
            if let p = profile {
                if p.stopRecordingOnUnplug { parts.append("Stopped recording") }
                if p.stopStreamingOnUnplug { parts.append("Stopped streaming") }
                if p.stopVirtualCamOnUnplug { parts.append("Stopped virtual camera") }
                if p.stopReplayBufferOnUnplug { parts.append("Stopped replay buffer") }
            }
            let body = parts.joined(separator: "\n")
            UserNotifier.post(
                title: "OBScene: trigger stopped",
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
        obsManager.isConnected = true
        obsManager.sceneCollections = ["Untitled"]
        obsManager.profiles = ["Untitled"]
        obsManager.scenes = ["Scene"]

        ActivityLog.shared.log(.info, "OBScene started")
        ActivityLog.shared.log(.info, "Connected to OBS WebSocket")
        ActivityLog.shared.log(.displayConnected, "External display connected (1 of 1)")
        ActivityLog.shared.log(.triggerScheduled, "Trigger scheduled in 5s")
        ActivityLog.shared.log(.triggerFired, "Switched to scene 'Scene'")
        ActivityLog.shared.log(.recordingStarted, "Recording started")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let renderWidth: CGFloat = 980
        let renderHeight: CGFloat = 720
        let view = SettingsView()
            .environmentObject(configStore)
            .environmentObject(obsManager)
            .frame(width: renderWidth, height: renderHeight)
            .background(Color(NSColor.windowBackgroundColor))

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: renderWidth, height: renderHeight)
        hosting.layoutSubtreeIfNeeded()
        let size = NSSize(width: renderWidth, height: renderHeight)

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
        bitmap.size = size

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

extension AppDelegate {
    fileprivate func renderMenuBarDropdownToPNG(path: String) {
        let view = MenuBarDropdownMockupView()
            .fixedSize(horizontal: true, vertical: true)

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 1200)
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: fitting)
        hosting.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2.0
        let pixelW = Int(fitting.width * scale)
        let pixelH = Int(fitting.height * scale)

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
            NSLog("[OBScene] Failed to create menu bitmap rep")
            return
        }
        bitmap.size = fitting

        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            NSLog("[OBScene] Failed to encode menu PNG")
            return
        }

        do {
            try data.write(to: URL(fileURLWithPath: path))
            NSLog("[OBScene] Rendered menu bar dropdown to \(path) (\(pixelW)x\(pixelH))")
        } catch {
            NSLog("[OBScene] Failed to write menu PNG \(path): \(error)")
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuState()
    }
}
